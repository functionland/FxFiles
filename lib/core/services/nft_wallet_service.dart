import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'package:fula_files/core/services/auth_service.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Deterministic EVM wallet derivation for non-web3 users.
///
/// Derives a private key from the existing Argon2id encryption key:
///   nftPrivateKey = HMAC-SHA256(existingKey, "nft-wallet") -> 32 bytes
///   nftAddress = keccak256(secp256k1_pubkey(nftPrivateKey))[12:] -> "0x..."
///
/// This service is only used as a fallback when the user doesn't have a
/// Reown AppKit wallet connected. The actual secp256k1 signing and address
/// derivation will be implemented in Phase 2 when the smart contract is deployed.
class NftWalletService {
  NftWalletService._();
  static final NftWalletService instance = NftWalletService._();

  Uint8List? _privateKey;
  String? _address;

  bool get hasWallet => _privateKey != null;
  String? get address => _address;

  /// Derive the NFT wallet from the existing encryption key.
  /// Returns the derived address, or null if no encryption key is available.
  Future<String?> deriveWallet() async {
    if (_address != null) return _address;

    try {
      // Get the existing Argon2id-derived encryption key
      final encryptionKeyHex = await SecureStorageService.instance.read(
        SecureStorageKeys.encryptionKey,
      );

      if (encryptionKeyHex == null || encryptionKeyHex.isEmpty) {
        debugPrint('NftWalletService: No encryption key available');
        return null;
      }

      // Decode the existing key (stored as hex)
      final existingKey = _hexToBytes(encryptionKeyHex);

      // Derive NFT private key: HMAC-SHA256(existingKey, "nft-wallet")
      final hmacSha256 = Hmac(sha256, existingKey);
      final digest = hmacSha256.convert(utf8.encode('nft-wallet'));
      _privateKey = Uint8List.fromList(digest.bytes);

      // Store for recovery
      await SecureStorageService.instance.write(
        SecureStorageKeys.nftWalletPrivateKey,
        _bytesToHex(_privateKey!),
      );

      // Address derivation requires secp256k1 + keccak256 (Phase 2)
      // For now, create a placeholder derived from the key hash
      final addressHash = sha256.convert(_privateKey!);
      _address = '0x${addressHash.toString().substring(0, 40)}';

      debugPrint('NftWalletService: Wallet derived: $_address');
      return _address;
    } catch (e) {
      debugPrint('NftWalletService: Derivation failed: $e');
      return null;
    }
  }

  /// Restore wallet from secure storage
  Future<String?> restoreWallet() async {
    if (_address != null) return _address;

    final storedKey = await SecureStorageService.instance.read(
      SecureStorageKeys.nftWalletPrivateKey,
    );
    if (storedKey == null || storedKey.isEmpty) return null;

    _privateKey = _hexToBytes(storedKey);
    final addressHash = sha256.convert(_privateKey!);
    _address = '0x${addressHash.toString().substring(0, 40)}';

    return _address;
  }

  /// Get or derive wallet address
  Future<String?> getAddress() async {
    if (_address != null) return _address;
    return await restoreWallet() ?? await deriveWallet();
  }

  /// Clear cached wallet state
  void clear() {
    _privateKey = null;
    _address = null;
  }

  Uint8List _hexToBytes(String hex) {
    final cleaned = hex.replaceFirst('0x', '');
    final result = Uint8List(cleaned.length ~/ 2);
    for (var i = 0; i < cleaned.length; i += 2) {
      result[i ~/ 2] = int.parse(cleaned.substring(i, i + 2), radix: 16);
    }
    return result;
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
