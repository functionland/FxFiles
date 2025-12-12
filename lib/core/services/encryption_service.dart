import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

class EncryptionService {
  EncryptionService._();
  static final EncryptionService instance = EncryptionService._();

  final _aesGcm = AesGcm.with256bits();
  final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 100000,
    bits: 256,
  );

  Future<Uint8List> generateKey() async {
    final secretKey = await _aesGcm.newSecretKey();
    final bytes = await secretKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> deriveKeyFromPassword(
    String password,
    Uint8List salt,
  ) async {
    final secretKey = await _pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final bytes = await secretKey.extractBytes();
    return Uint8List.fromList(bytes);
  }

  Future<Uint8List> deriveKeyFromUserId(String userId) async {
    final salt = utf8.encode('fula-files-encryption-salt-v1');
    return await deriveKeyFromPassword(userId, Uint8List.fromList(salt));
  }

  Future<Uint8List> encrypt(Uint8List data, Uint8List key) async {
    final secretKey = SecretKey(key);
    final nonce = _aesGcm.newNonce();

    final secretBox = await _aesGcm.encrypt(
      data,
      secretKey: secretKey,
      nonce: nonce,
    );

    final result = Uint8List(
      nonce.length + secretBox.mac.bytes.length + secretBox.cipherText.length,
    );
    var offset = 0;

    result.setRange(offset, offset + nonce.length, nonce);
    offset += nonce.length;

    result.setRange(offset, offset + secretBox.mac.bytes.length, secretBox.mac.bytes);
    offset += secretBox.mac.bytes.length;

    result.setRange(offset, offset + secretBox.cipherText.length, secretBox.cipherText);

    return result;
  }

  Future<Uint8List> decrypt(Uint8List encryptedData, Uint8List key) async {
    if (encryptedData.length < 12 + 16) {
      throw EncryptionException('Invalid encrypted data');
    }

    final secretKey = SecretKey(key);
    var offset = 0;

    final nonce = encryptedData.sublist(offset, offset + 12);
    offset += 12;

    final mac = Mac(encryptedData.sublist(offset, offset + 16));
    offset += 16;

    final cipherText = encryptedData.sublist(offset);

    final secretBox = SecretBox(
      cipherText,
      nonce: nonce,
      mac: mac,
    );

    try {
      final decrypted = await _aesGcm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return Uint8List.fromList(decrypted);
    } catch (e) {
      throw EncryptionException('Decryption failed: $e');
    }
  }

  Future<String> encryptStringAsync(String data, Uint8List key) async {
    final encrypted = await encrypt(utf8.encode(data), key);
    return base64Encode(encrypted);
  }

  Future<String> decryptStringAsync(String encryptedData, Uint8List key) async {
    final decoded = base64Decode(encryptedData);
    final decrypted = await decrypt(decoded, key);
    return utf8.decode(decrypted);
  }

  Uint8List generateSalt([int length = 32]) {
    final random = SecureRandom.fast;
    final salt = Uint8List(length);
    for (var i = 0; i < length; i++) {
      salt[i] = random.nextInt(256);
    }
    return salt;
  }

  Future<String> hashDataAsync(Uint8List data) async {
    final sha256 = Sha256();
    final hash = await sha256.hash(data);
    return base64Encode(hash.bytes);
  }

  Future<bool> verifyHash(Uint8List data, String expectedHash) async {
    final actualHash = await hashDataAsync(data);
    return actualHash == expectedHash;
  }

  // ============================================================================
  // KEY PAIR GENERATION AND KEY WRAPPING FOR SHARING
  // Based on Fula HPKE pattern: X25519 DH + AES-256-GCM key wrapping
  // ============================================================================

  final _x25519 = X25519();

  Future<KeyPairData> generateKeyPair() async {
    final keyPair = await _x25519.newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    final privateKeyBytes = await keyPair.extractPrivateKeyBytes();
    
    return KeyPairData(
      publicKey: Uint8List.fromList(publicKey.bytes),
      privateKey: Uint8List.fromList(privateKeyBytes),
    );
  }

  Future<Uint8List> wrapKeyForRecipient(
    Uint8List dek,
    Uint8List recipientPublicKey,
    Uint8List ephemeralPrivateKey,
  ) async {
    final sharedSecret = await _deriveSharedSecret(
      ephemeralPrivateKey,
      recipientPublicKey,
    );
    final wrapKey = await _deriveWrapKey(sharedSecret);
    return await encrypt(dek, wrapKey);
  }

  Future<Uint8List> unwrapKeyFromSender(
    Uint8List wrappedDek,
    Uint8List ephemeralPublicKey,
    Uint8List recipientPrivateKey,
  ) async {
    final sharedSecret = await _deriveSharedSecret(
      recipientPrivateKey,
      ephemeralPublicKey,
    );
    final wrapKey = await _deriveWrapKey(sharedSecret);
    return await decrypt(wrappedDek, wrapKey);
  }

  Future<Uint8List> _deriveSharedSecret(
    Uint8List privateKey,
    Uint8List publicKey,
  ) async {
    final keyPair = await _x25519.newKeyPairFromSeed(privateKey);
    final remotePublicKey = SimplePublicKey(publicKey, type: KeyPairType.x25519);
    
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: remotePublicKey,
    );
    
    return Uint8List.fromList(await sharedSecret.extractBytes());
  }

  Future<Uint8List> _deriveWrapKey(Uint8List sharedSecret) async {
    final hkdf = Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    );
    
    final derivedKey = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: utf8.encode('fula-hpke-v1'),
      info: utf8.encode('wrap-key'),
    );
    
    return Uint8List.fromList(await derivedKey.extractBytes());
  }
}

class KeyPairData {
  final Uint8List publicKey;
  final Uint8List privateKey;

  KeyPairData({
    required this.publicKey,
    required this.privateKey,
  });
}

class EncryptionException implements Exception {
  final String message;
  EncryptionException(this.message);

  @override
  String toString() => 'EncryptionException: $message';
}
