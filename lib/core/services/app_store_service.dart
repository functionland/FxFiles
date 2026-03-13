import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/app_models.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

class AppStoreService {
  AppStoreService._();
  static final AppStoreService instance = AppStoreService._();

  static const _uuid = Uuid();
  static final _random = Random.secure();
  static final _aesGcm = crypto.AesGcm.with256bits();

  // App registry — ships with app code
  static final List<AppDefinition> availableApps = [
    const AppDefinition(
      id: 'whatsapp',
      name: 'WhatsApp Backup',
      description: 'Daily incremental backup of WhatsApp messages and media',
      iconName: 'messageCircle',
      colorValue: 0xFF25D366,
      supportedPlatforms: ['android', 'ios'],
      dataPathAndroid: '/storage/emulated/0/Android/media/com.whatsapp/WhatsApp',
      dataPathAndroidLegacy: '/storage/emulated/0/WhatsApp',
    ),
    const AppDefinition(
      id: 'whatsapp_business',
      name: 'WhatsApp Business Backup',
      description: 'Daily incremental backup of WhatsApp Business messages and media',
      iconName: 'briefcase',
      colorValue: 0xFF54C255,
      supportedPlatforms: ['android', 'ios'],
      dataPathAndroid: '/storage/emulated/0/Android/media/com.whatsapp.w4b/WhatsApp Business',
      dataPathAndroidLegacy: '/storage/emulated/0/WhatsApp Business',
    ),
  ];

  late Box<ActivatedApp> _activatedAppsBox;
  late Box<BackupRecord> _backupRecordsBox;
  late Box<BackupFileEntry> _fileIndexBox;
  bool _isInitialized = false;

  final _onAppChangedController = StreamController<List<ActivatedApp>>.broadcast();
  Stream<List<ActivatedApp>> get onAppChanged => _onAppChangedController.stream;

  // Cloud sync state
  static const String _appMetadataBucket = 'app-metadata';
  bool _metaBucketChecked = false;
  bool _metaBucketExists = false;
  bool _syncScheduled = false;
  static const Duration _syncDebounce = Duration(seconds: 5);

  Future<void> init() async {
    if (_isInitialized) return;

    try {
      if (!Hive.isAdapterRegistered(40)) {
        Hive.registerAdapter(ActivatedAppAdapter());
      }
      if (!Hive.isAdapterRegistered(41)) {
        Hive.registerAdapter(AppStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(42)) {
        Hive.registerAdapter(BackupRecordAdapter());
      }
      if (!Hive.isAdapterRegistered(43)) {
        Hive.registerAdapter(BackupStatusAdapter());
      }
      if (!Hive.isAdapterRegistered(44)) {
        Hive.registerAdapter(BackupFileEntryAdapter());
      }
      if (!Hive.isAdapterRegistered(45)) {
        Hive.registerAdapter(BackupCategoryAdapter());
      }

      _activatedAppsBox = await Hive.openBox<ActivatedApp>('activated_apps');
      _backupRecordsBox = await Hive.openBox<BackupRecord>('backup_records');
      _fileIndexBox = await Hive.openBox<BackupFileEntry>('backup_file_index');
      _isInitialized = true;
      debugPrint('AppStoreService initialized with ${_activatedAppsBox.length} activated apps');
    } catch (e) {
      debugPrint('Failed to initialize AppStoreService: $e');
    }
  }

  // ============================================================================
  // APP REGISTRY
  // ============================================================================

  static AppDefinition? getAppDefinition(String appId) {
    try {
      return availableApps.firstWhere((a) => a.id == appId);
    } catch (_) {
      return null;
    }
  }

  List<ActivatedApp> getActivatedApps() {
    if (!_isInitialized) return [];
    return _activatedAppsBox.values
        .where((a) => a.status != AppStatus.disabled)
        .toList()
      ..sort((a, b) => b.activatedAt.compareTo(a.activatedAt));
  }

  bool isAppActivated(String appId) {
    if (!_isInitialized) return false;
    try {
      final app = _activatedAppsBox.values.firstWhere((a) => a.appId == appId);
      return app.status == AppStatus.active;
    } catch (_) {
      return false;
    }
  }

  ActivatedApp? getActivatedApp(String appId) {
    if (!_isInitialized) return null;
    try {
      return _activatedAppsBox.values.firstWhere((a) => a.appId == appId);
    } catch (_) {
      return null;
    }
  }

  Future<ActivatedApp> activateApp(String appId, {String? iosFolderPath}) async {
    if (!_isInitialized) await init();

    // Check if already activated
    final existing = getActivatedApp(appId);
    if (existing != null && existing.status == AppStatus.active) {
      return existing;
    }

    final app = ActivatedApp(
      appId: appId,
      activatedAt: DateTime.now(),
      status: AppStatus.active,
      iosFolderPath: iosFolderPath,
    );

    await _activatedAppsBox.put(appId, app);
    _notifyChange();
    _scheduleSyncToCloud();
    return app;
  }

  Future<void> deactivateApp(String appId) async {
    if (!_isInitialized) return;

    final app = getActivatedApp(appId);
    if (app == null) return;

    app.status = AppStatus.disabled;
    await app.save();
    _notifyChange();
    _scheduleSyncToCloud();
  }

  Future<void> updateIosFolderPath(String appId, String path) async {
    final app = getActivatedApp(appId);
    if (app == null) return;
    app.iosFolderPath = path;
    await app.save();
    _notifyChange();
  }

  Future<void> updateLastBackupAt(String appId, DateTime time) async {
    final app = getActivatedApp(appId);
    if (app == null) return;
    app.lastBackupAt = time;
    await app.save();
    _notifyChange();
  }

  void _notifyChange() {
    _onAppChangedController.add(getActivatedApps());
  }

  // ============================================================================
  // BACKUP RECORDS
  // ============================================================================

  List<BackupRecord> getBackupHistory(String appId) {
    if (!_isInitialized) return [];
    return _backupRecordsBox.values
        .where((r) => r.appId == appId)
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
  }

  Future<BackupRecord> createBackupRecord(String appId) async {
    final record = BackupRecord(
      id: _uuid.v4(),
      appId: appId,
      startedAt: DateTime.now(),
      platform: Platform.isAndroid ? 'android' : (Platform.isIOS ? 'ios' : 'desktop'),
    );
    await _backupRecordsBox.put(record.id, record);
    return record;
  }

  Future<void> updateBackupRecord(BackupRecord record) async {
    await _backupRecordsBox.put(record.id, record);
  }

  Future<void> deleteBackupRecord(String backupId) async {
    await _backupRecordsBox.delete(backupId);
    // Remove orphaned file entries
    final orphanKeys = _fileIndexBox.values
        .where((e) => e.backupId == backupId)
        .map((e) => e.relativePath)
        .toList();
    for (final key in orphanKeys) {
      // Only delete if no other backup references this file
      final otherRefs = _fileIndexBox.values
          .where((e) => e.relativePath == key && e.backupId != backupId);
      if (otherRefs.isEmpty) {
        await _fileIndexBox.delete(key);
      }
    }
  }

  // ============================================================================
  // FILE INDEX
  // ============================================================================

  Box<BackupFileEntry> get fileIndexBox {
    assert(_isInitialized, 'AppStoreService not initialized');
    return _fileIndexBox;
  }

  BackupFileEntry? getFileEntry(String relativePath) {
    if (!_isInitialized) return null;
    return _fileIndexBox.get(relativePath);
  }

  Future<void> putFileEntry(BackupFileEntry entry) async {
    await _fileIndexBox.put(entry.relativePath, entry);
  }

  List<BackupFileEntry> getFileEntriesForBackup(String backupId) {
    if (!_isInitialized) return [];
    return _fileIndexBox.values.where((e) => e.backupId == backupId).toList();
  }

  List<BackupFileEntry> getAllFileEntries() {
    if (!_isInitialized) return [];
    return _fileIndexBox.values.toList();
  }

  // ============================================================================
  // PASSWORD MANAGEMENT
  // ============================================================================

  Future<void> setAppPassword(String appId, String password) async {
    final salt = _generateSalt(32);
    final key = await _deriveKeyFromPassword(password, salt);
    // Store a known verifier: encrypt a fixed string
    final verifier = await _encrypt(Uint8List.fromList(utf8.encode('FxFiles-verified')), key);

    await SecureStorageService.instance.write(
      '${SecureStorageKeys.appPasswordSaltPrefix}$appId',
      base64Encode(salt),
    );
    await SecureStorageService.instance.write(
      '${SecureStorageKeys.appPasswordVerifierPrefix}$appId',
      base64Encode(verifier),
    );

    final app = getActivatedApp(appId);
    if (app != null) {
      app.hasPassword = true;
      await app.save();
      _notifyChange();
      _scheduleSyncToCloud();
    }
  }

  Future<bool> verifyAppPassword(String appId, String password) async {
    try {
      final saltStr = await SecureStorageService.instance.read(
        '${SecureStorageKeys.appPasswordSaltPrefix}$appId',
      );
      final verifierStr = await SecureStorageService.instance.read(
        '${SecureStorageKeys.appPasswordVerifierPrefix}$appId',
      );
      if (saltStr == null || verifierStr == null) return false;

      final salt = Uint8List.fromList(base64Decode(saltStr));
      final key = await _deriveKeyFromPassword(password, salt);
      final verifier = Uint8List.fromList(base64Decode(verifierStr));

      final decrypted = await _decrypt(verifier, key);
      return utf8.decode(decrypted) == 'FxFiles-verified';
    } catch (_) {
      return false;
    }
  }

  Future<Uint8List?> deriveEncryptionKey(String appId, String password) async {
    final saltStr = await SecureStorageService.instance.read(
      '${SecureStorageKeys.appPasswordSaltPrefix}$appId',
    );
    if (saltStr == null) return null;
    final salt = Uint8List.fromList(base64Decode(saltStr));
    return _deriveKeyFromPassword(password, salt);
  }

  Future<void> removeAppPassword(String appId) async {
    await SecureStorageService.instance.delete(
      '${SecureStorageKeys.appPasswordSaltPrefix}$appId',
    );
    await SecureStorageService.instance.delete(
      '${SecureStorageKeys.appPasswordVerifierPrefix}$appId',
    );
    final app = getActivatedApp(appId);
    if (app != null) {
      app.hasPassword = false;
      await app.save();
      _notifyChange();
    }
  }

  // ============================================================================
  // CRYPTO HELPERS (same pattern as sharing_service.dart)
  // ============================================================================

  Future<Uint8List> _deriveKeyFromPassword(String password, Uint8List salt) async {
    final pbkdf2 = crypto.Pbkdf2(
      macAlgorithm: crypto.Hmac.sha256(),
      iterations: 100000,
      bits: 256,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: crypto.SecretKey(utf8.encode(password)),
      nonce: salt,
    );

    return Uint8List.fromList(await secretKey.extractBytes());
  }

  Future<Uint8List> encrypt(Uint8List data, Uint8List key) async {
    return _encrypt(data, key);
  }

  Future<Uint8List> decrypt(Uint8List data, Uint8List key) async {
    return _decrypt(data, key);
  }

  Future<Uint8List> _encrypt(Uint8List data, Uint8List key) async {
    final secretKey = crypto.SecretKey(key);
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(data, secretKey: secretKey, nonce: nonce);

    return Uint8List.fromList([
      ...nonce,
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  Future<Uint8List> _decrypt(Uint8List encryptedData, Uint8List key) async {
    final nonceLength = _aesGcm.nonceLength;
    final macLength = _aesGcm.macAlgorithm.macLength;

    final nonce = encryptedData.sublist(0, nonceLength);
    final cipherText = encryptedData.sublist(nonceLength, encryptedData.length - macLength);
    final mac = encryptedData.sublist(encryptedData.length - macLength);

    final secretKey = crypto.SecretKey(key);
    final secretBox = crypto.SecretBox(cipherText, nonce: nonce, mac: crypto.Mac(mac));
    final decrypted = await _aesGcm.decrypt(secretBox, secretKey: secretKey);

    return Uint8List.fromList(decrypted);
  }

  Uint8List _generateSalt(int length) {
    return Uint8List.fromList(List.generate(length, (_) => _random.nextInt(256)));
  }

  // ============================================================================
  // CLOUD SYNC (same pattern as nft_service.dart)
  // ============================================================================

  void _scheduleSyncToCloud() {
    if (_syncScheduled) return;
    _syncScheduled = true;

    Future.delayed(_syncDebounce, () async {
      _syncScheduled = false;
      await syncToCloud();
    });
  }

  Future<void> syncToCloud() async {
    if (_metaBucketChecked && !_metaBucketExists) return;
    if (!FulaApiService.instance.isConfigured) return;

    if (!await _ensureMetadataBucketExists()) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final apps = _activatedAppsBox.values.map((a) => a.toJson()).toList();

      final jsonStr = jsonEncode({
        'activatedApps': apps,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final data = Uint8List.fromList(utf8.encode(jsonStr));

      final key = '.fula/apps/$userId.json';
      await FulaApiService.instance.encryptAndUpload(
        _appMetadataBucket,
        key,
        data,
        encryptionKey,
        contentType: 'application/json',
      );

      debugPrint('App metadata synced to cloud: ${apps.length} apps');
    } catch (e) {
      debugPrint('AppStoreService: syncToCloud error: $e');
    }
  }

  Future<void> restoreFromCloud() async {
    if (!_isInitialized) await init();
    if (!FulaApiService.instance.isConfigured) return;

    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;

      final userId = await _getUserId();
      if (userId == null) return;

      final key = '.fula/apps/$userId.json';
      final data = await FulaApiService.instance.downloadAndDecrypt(
        _appMetadataBucket,
        key,
        encryptionKey,
      );

      final jsonStr = utf8.decode(data);
      final json = jsonDecode(jsonStr) as Map<String, dynamic>;
      final appsList = json['activatedApps'] as List<dynamic>? ?? [];

      if (_activatedAppsBox.isEmpty && appsList.isNotEmpty) {
        for (final appJson in appsList) {
          final app = ActivatedApp.fromJson(appJson as Map<String, dynamic>);
          await _activatedAppsBox.put(app.appId, app);
        }
        _notifyChange();
        debugPrint('App metadata restored from cloud: ${appsList.length} apps');
      }
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('NoSuchKey') ||
          errorStr.contains('Object not found') ||
          errorStr.contains('404')) {
        debugPrint('App restore: no cloud data found (new user or never synced)');
      } else {
        debugPrint('AppStoreService: restoreFromCloud error: $e');
      }
    }
  }

  Future<bool> _ensureMetadataBucketExists() async {
    if (_metaBucketChecked && _metaBucketExists) return true;

    try {
      await FulaApiService.instance.createBucket(_appMetadataBucket);
      _metaBucketExists = true;
      _metaBucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('BucketAlreadyExists') ||
          errorStr.contains('BucketAlreadyOwnedByYou')) {
        _metaBucketExists = true;
        _metaBucketChecked = true;
        return true;
      }
      _metaBucketExists = false;
      _metaBucketChecked = false;
      return false;
    }
  }

  Future<String?> _getUserId() async {
    try {
      final publicKey = await AuthService.instance.getPublicKeyString();
      if (publicKey == null || publicKey.isEmpty) return null;
      final bytes = utf8.encode(publicKey);
      final hash = sha256.convert(bytes);
      return hash.toString().substring(0, 16);
    } catch (e) {
      return null;
    }
  }
}
