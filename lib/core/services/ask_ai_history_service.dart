import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:fula_files/core/models/ask_ai_history.dart';
import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/bucket_version_resolver.dart';
import 'package:fula_files/core/services/fula_api_service.dart';
import 'package:fula_files/core/models/fula_object.dart';
import 'package:fula_files/core/utils/hive_cipher.dart';

class AskAiHistoryService {
  AskAiHistoryService._();
  static final AskAiHistoryService instance = AskAiHistoryService._();

  static const String _boxName = 'askai_history';
  static const String _metadataBucket = 'askai-metadata';
  
  String get _writeBucket => BucketVersionResolver.writeBucket(_metadataBucket);
  
  late Box<AskAiHistory> _historyBox;
  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  bool _bucketChecked = false;
  bool _bucketExists = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      if (!Hive.isAdapterRegistered(28)) {
        Hive.registerAdapter(AskAiHistoryAdapter());
      }
      final cipher = await getHiveMetadataCipher();
      
      try {
        _historyBox = await Hive.openBox<AskAiHistory>(_boxName, encryptionCipher: cipher);
      } catch (e) {
        debugPrint('AskAiHistoryService: reopening fresh after open error: $e');
        await Hive.deleteBoxFromDisk(_boxName);
        _historyBox = await Hive.openBox<AskAiHistory>(_boxName, encryptionCipher: cipher);
      }
      
      _isInitialized = true;
      debugPrint('AskAiHistoryService initialized with ${_historyBox.length} chats');
    } catch (e) {
      debugPrint('Failed to initialize AskAiHistoryService: $e');
    }
  }

  Future<void> clearAll() async {
    if (!_isInitialized) return;
    await _historyBox.clear();
  }
  
  Future<bool> _ensureBucketExists() async {
    if (_bucketChecked && _bucketExists) return true;
    try {
      await FulaApiService.instance.createBucket(_writeBucket);
      _bucketExists = true;
      _bucketChecked = true;
      return true;
    } catch (e) {
      final errorStr = e.toString();
      if (errorStr.contains('BucketAlreadyExists') || errorStr.contains('BucketAlreadyOwnedByYou') || errorStr.contains('already exists')) {
        _bucketExists = true;
        _bucketChecked = true;
        return true;
      }
      _bucketExists = false;
      _bucketChecked = true;
      return false;
    }
  }

  List<AskAiHistory> getHistoryForTag(String tagId) {
    if (!_isInitialized) return [];
    return _historyBox.values
      .where((h) => h.tagId == tagId && !h.deleted)
      .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<void> saveHistory({
    required String tagId,
    required String tagName,
    required List<String> filenames,
    required String prompt,
    required String response,
  }) async {
    if (!_isInitialized) await init();
    
    final id = const Uuid().v4();
    final history = AskAiHistory(
      id: id,
      tagId: tagId,
      tagName: tagName,
      filenames: filenames,
      prompt: prompt,
      response: response,
      createdAt: DateTime.now(),
    );
    
    await _historyBox.put(id, history);
    
    // Fire and forget cloud sync
    _uploadHistory(history).catchError((e) {
      debugPrint('AskAiHistoryService: bg upload error: $e');
    });
  }

  Future<void> deleteHistory(String id) async {
    if (!_isInitialized) return;
    final item = _historyBox.get(id);
    if (item == null) return;
    
    final tombstone = AskAiHistory(
      id: item.id,
      tagId: item.tagId,
      tagName: item.tagName,
      filenames: item.filenames,
      prompt: item.prompt,
      response: item.response,
      createdAt: item.createdAt,
      deleted: true,
    );
    
    await _historyBox.put(id, tombstone);
    _uploadHistory(tombstone).catchError((e) {
      debugPrint('AskAiHistoryService: bg upload tombstone error: $e');
    });
  }

  Future<void> _uploadHistory(AskAiHistory history) async {
    if (!await _ensureBucketExists()) return;
    
    final encryptionKey = await AuthService.instance.getEncryptionKey();
    if (encryptionKey == null) return;
    
    final jsonStr = jsonEncode(history.toJson());
    final data = Uint8List.fromList(utf8.encode(jsonStr));
    
    final key = '.fula/askai/${history.tagId}/${history.id}.json';
    
    await FulaApiService.instance.encryptAndUpload(
      _writeBucket,
      key,
      data,
      encryptionKey,
      contentType: 'application/json',
    );
  }

  Future<void> syncHistoryForTag(String tagId) async {
    if (!_isInitialized) await init();
    try {
      final encryptionKey = await AuthService.instance.getEncryptionKey();
      if (encryptionKey == null) return;
      
      final prefix = '.fula/askai/$tagId/';
      
      List<FulaObject> objects = [];
      try {
        objects = await FulaApiService.instance.listObjects(_writeBucket, prefix: prefix);
      } catch (e) {
        if (e.toString().contains('NoSuchBucket') || e.toString().contains('bucket not found')) {
          return; // Nothing to sync
        }
        rethrow;
      }
      
      for (final obj in objects) {
        if (!obj.key.endsWith('.json')) continue;
        
        final id = obj.key.split('/').last.replaceAll('.json', '');
        
        final localItem = _historyBox.get(id);
        if (localItem != null && localItem.deleted) {
           continue; 
        }
        
        try {
          final data = await FulaApiService.instance.downloadAndDecrypt(
            _writeBucket,
            obj.key,
            encryptionKey,
          );
          
          final jsonMap = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
          final remoteHistory = AskAiHistory.fromJson(jsonMap);
          
          if (localItem == null || remoteHistory.deleted) {
            await _historyBox.put(remoteHistory.id, remoteHistory);
          }
        } catch (e) {
          debugPrint('Failed to fetch/decrypt AskAiHistory ${obj.key}: $e');
        }
      }
    } catch (e) {
      debugPrint('Failed to sync AskAiHistory for tag $tagId: $e');
    }
  }
}
