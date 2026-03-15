import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:wallet/wallet.dart' show EthereumAddress, EtherAmount;
import 'package:web3dart/web3dart.dart';

import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

/// Deterministic EVM wallet derivation for non-web3 users.
///
/// Derives a private key from the existing Argon2id encryption key (stored as base64):
///   nftPrivateKey = HMAC-SHA256("nft-wallet", base64Decode(encryptionKey)) -> 32 bytes
///   nftAddress = keccak256(secp256k1_pubkey(nftPrivateKey))[12:] -> "0x..."
///
/// This service provides an internal wallet so non-crypto users can mint/claim/burn
/// without connecting an external wallet like MetaMask.
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
      // Get the existing Argon2id-derived encryption key (stored as base64)
      final encryptionKeyBase64 = await SecureStorageService.instance.read(
        SecureStorageKeys.encryptionKey,
      );

      if (encryptionKeyBase64 == null || encryptionKeyBase64.isEmpty) {
        debugPrint('NftWalletService: No encryption key available');
        return null;
      }

      // Decode the existing key (stored as base64)
      final existingKey = base64Decode(encryptionKeyBase64);

      // Derive NFT private key: HMAC-SHA256(existingKey, "nft-wallet")
      final hmacSha256 = Hmac(sha256, utf8.encode('nft-wallet'));
      final digest = hmacSha256.convert(existingKey);
      _privateKey = Uint8List.fromList(digest.bytes);

      // Store for recovery
      await SecureStorageService.instance.write(
        SecureStorageKeys.nftWalletPrivateKey,
        _bytesToHex(_privateKey!),
      );

      // Derive EVM address using web3dart (secp256k1 + keccak256)
      final ethKey = EthPrivateKey(_privateKey!);
      _address = ethKey.address.eip55With0x;

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
    final ethKey = EthPrivateKey(_privateKey!);
    _address = ethKey.address.eip55With0x;

    return _address;
  }

  /// Get or derive wallet address
  Future<String?> getAddress() async {
    if (_address != null) return _address;
    return await restoreWallet() ?? await deriveWallet();
  }

  /// Send a signed transaction using the internal wallet.
  /// Returns the transaction hash.
  Future<String> sendSignedTransaction({
    required SupportedChain chain,
    required String to,
    required String encodedData,
    BigInt? value,
  }) async {
    if (_privateKey == null) {
      await deriveWallet();
    }
    if (_privateKey == null) {
      throw Exception('Internal wallet not available — sign in first');
    }

    if (chain.rpcUrl == null) {
      throw Exception('No RPC URL for chain ${chain.chainName}');
    }

    final httpClient = http.Client();
    try {
      final client = Web3Client(chain.rpcUrl!, httpClient);
      final credentials = EthPrivateKey(_privateKey!);

      final tx = Transaction(
        to: EthereumAddress.fromHex(to),
        data: _hexToBytes(encodedData.replaceFirst('0x', '')),
        value: value != null ? EtherAmount.inWei(value) : EtherAmount.zero(),
      );

      final txHash = await client.sendTransaction(
        credentials,
        tx,
        chainId: chain.chainId,
      );

      return txHash;
    } finally {
      httpClient.close();
    }
  }

  /// Send an ERC20 approve transaction using the internal wallet.
  Future<String> sendApproveTransaction({
    required SupportedChain chain,
    required String tokenAddress,
    required String spender,
    required BigInt amount,
  }) async {
    // ABI encode: approve(address,uint256)
    const approveSelector = '095ea7b3';
    final spenderHex = spender.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
    final amountHex = amount.toRadixString(16).padLeft(64, '0');
    final data = '0x$approveSelector$spenderHex$amountHex';

    return sendSignedTransaction(
      chain: chain,
      to: tokenAddress,
      encodedData: data,
    );
  }

  // ============================================================================
  // EIP-712 SIGNING (for gasless meta-tx claims on Base)
  // ============================================================================

  /// Build the EIP-712 domain separator for FulaFileNFT.
  Uint8List _buildDomainSeparator(int chainId, String contractAddress) {
    // EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
    final domainTypeHash = _keccak256Utf8(
      'EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');
    final nameHash = _keccak256Utf8('FulaFileNFT');
    final versionHash = _keccak256Utf8('1');

    final encoded = _abiEncode([
      domainTypeHash,
      nameHash,
      versionHash,
      _uint256Bytes(BigInt.from(chainId)),
      _addressBytes(contractAddress),
    ]);
    return _keccak256(encoded);
  }

  /// Sign a ClaimNFTMeta EIP-712 typed data.
  /// [claimKey] is the public key (keccak256 of secret) — we sign over this, NOT the secret.
  /// Returns the raw ECDSA signature as a hex string (no 0x prefix).
  Future<String> signClaimNftMeta({
    required String claimKey,
    required String claimer,
    required int deadline,
    required int nonce,
    required int chainId,
    required String contractAddress,
  }) async {
    final typeHash = _keccak256Utf8(
      'ClaimNFTMeta(bytes32 claimKey,address claimer,uint256 deadline,uint256 nonce)');
    final structHash = _keccak256(_abiEncode([
      typeHash,
      _bytes32FromHex(claimKey),
      _addressBytes(claimer),
      _uint256Bytes(BigInt.from(deadline)),
      _uint256Bytes(BigInt.from(nonce)),
    ]));
    return _signEip712(structHash, chainId, contractAddress);
  }

  /// Sign a BurnMeta EIP-712 typed data.
  Future<String> signBurnMeta({
    required String claimKey,
    required int tokenId,
    required int amount,
    required String holder,
    required int deadline,
    required int nonce,
    required int chainId,
    required String contractAddress,
  }) async {
    final typeHash = _keccak256Utf8(
      'BurnMeta(bytes32 claimKey,uint256 tokenId,uint256 amount,address holder,uint256 deadline,uint256 nonce)');
    final structHash = _keccak256(_abiEncode([
      typeHash,
      _bytes32FromHex(claimKey),
      _uint256Bytes(BigInt.from(tokenId)),
      _uint256Bytes(BigInt.from(amount)),
      _addressBytes(holder),
      _uint256Bytes(BigInt.from(deadline)),
      _uint256Bytes(BigInt.from(nonce)),
    ]));
    return _signEip712(structHash, chainId, contractAddress);
  }

  /// Sign a TransferBackMeta EIP-712 typed data.
  Future<String> signTransferBackMeta({
    required String claimKey,
    required int tokenId,
    required String holder,
    required int deadline,
    required int nonce,
    required int chainId,
    required String contractAddress,
  }) async {
    final typeHash = _keccak256Utf8(
      'TransferBackMeta(bytes32 claimKey,uint256 tokenId,address holder,uint256 deadline,uint256 nonce)');
    final structHash = _keccak256(_abiEncode([
      typeHash,
      _bytes32FromHex(claimKey),
      _uint256Bytes(BigInt.from(tokenId)),
      _addressBytes(holder),
      _uint256Bytes(BigInt.from(deadline)),
      _uint256Bytes(BigInt.from(nonce)),
    ]));
    return _signEip712(structHash, chainId, contractAddress);
  }

  /// Core EIP-712 signing: build digest and sign with raw ECDSA.
  Future<String> _signEip712(Uint8List structHash, int chainId, String contractAddress) async {
    if (_privateKey == null) await deriveWallet();
    if (_privateKey == null) throw Exception('Internal wallet not available');

    final domainSep = _buildDomainSeparator(chainId, contractAddress);

    // digest = keccak256("\x19\x01" || domainSeparator || structHash)
    final prefix = Uint8List.fromList([0x19, 0x01]);
    final digestInput = Uint8List.fromList([...prefix, ...domainSep, ...structHash]);
    final digest = _keccak256(digestInput);

    // Raw ECDSA sign using web3dart's low-level sign function
    final ecSig = sign(digest, _privateKey!);
    // Build 65-byte signature: r (32) + s (32) + v (1)
    final rBytes = _bigIntToBytes32(ecSig.r);
    final sBytes = _bigIntToBytes32(ecSig.s);
    final v = ecSig.v;
    final sigBytes = Uint8List.fromList([...rBytes, ...sBytes, v]);
    return '0x${_bytesToHex(sigBytes)}';
  }

  // EIP-712 helpers

  Uint8List _keccak256Utf8(String input) {
    return keccakUtf8(input);
  }

  Uint8List _keccak256(Uint8List input) {
    return keccak256(input);
  }

  Uint8List _abiEncode(List<Uint8List> values) {
    final result = <int>[];
    for (final v in values) {
      // Each value is already 32 bytes padded
      result.addAll(v);
    }
    return Uint8List.fromList(result);
  }

  Uint8List _uint256Bytes(BigInt value) {
    final hex = value.toRadixString(16).padLeft(64, '0');
    return _hexToBytes(hex);
  }

  Uint8List _addressBytes(String address) {
    final cleaned = address.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
    return _hexToBytes(cleaned);
  }

  Uint8List _bytes32FromHex(String hex) {
    final cleaned = hex.replaceFirst('0x', '').padLeft(64, '0');
    return _hexToBytes(cleaned);
  }

  Uint8List _bigIntToBytes32(BigInt value) {
    final hex = value.toUnsigned(256).toRadixString(16).padLeft(64, '0');
    return _hexToBytes(hex);
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
