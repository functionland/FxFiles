import 'dart:convert';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Returns a [HiveAesCipher] seeded from a per-install AES-256 key stored in
/// [SecureStorageService]. Generates and persists the key on first use.
///
/// Use to encrypt local Hive boxes that hold sensitive metadata (face
/// embeddings, OCR tags). The key never leaves SecureStorage.
Future<HiveAesCipher> getHiveMetadataCipher() async {
  final storage = SecureStorageService.instance;
  String? b64 = await storage.read(SecureStorageKeys.hiveMetadataKey);
  List<int> key;
  if (b64 == null || b64.isEmpty) {
    key = Hive.generateSecureKey();
    await storage.write(
      SecureStorageKeys.hiveMetadataKey,
      base64Encode(key),
    );
  } else {
    key = base64Decode(b64);
  }
  return HiveAesCipher(key);
}
