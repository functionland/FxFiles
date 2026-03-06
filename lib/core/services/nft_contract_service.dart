import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:fula_files/core/models/billing/supported_chain.dart';

/// ABI encoding and RPC read calls for the NFT smart contract.
///
/// Follows the existing WalletService._encodeErc20Transfer pattern:
/// manual hex encoding without web3dart dependency.
///
/// Function selectors will be filled in after the contract ABI is finalized (Phase 2).
class NftContractService {
  NftContractService._();
  static final NftContractService instance = NftContractService._();

  // Placeholder selectors — will be replaced with actual values from deployed ABI
  // mintWithFula(string,uint256,uint256)
  static const String _mintWithFulaSelector = '00000000';
  // createClaimOffer(uint256,address,uint256)
  static const String _createClaimOfferSelector = '00000000';
  // claimNFT(bytes32)
  static const String _claimNftSelector = '00000000';
  // transferBack(uint256,address,uint256)
  static const String _transferBackSelector = '00000000';
  // balanceOf(address,uint256) — standard ERC1155
  static const String _balanceOfSelector = '00fdd58e';
  // getTokenInfo(uint256)
  static const String _getTokenInfoSelector = '00000000';
  // getClaimOffer(bytes32)
  static const String _getClaimOfferSelector = '00000000';
  // getCreatorTokens(address)
  static const String _getCreatorTokensSelector = '00000000';
  // approve(address,uint256) — standard ERC20
  static const String _approveSelector = '095ea7b3';

  // ============================================================================
  // ABI ENCODING
  // ============================================================================

  /// Encode ERC20 approve(address spender, uint256 amount)
  String encodeApprove(String spenderAddress, BigInt amount) {
    final address = _padAddress(spenderAddress);
    final amountHex = _padUint256(amount);
    return '0x$_approveSelector$address$amountHex';
  }

  /// Encode mintWithFula(string ipfsCid, uint256 fulaPerNft, uint256 count)
  String encodeMintWithFula(String ipfsCid, BigInt fulaPerNft, int count) {
    // Dynamic string encoding: offset + fulaPerNft + count + string length + string data
    // Param 0: offset to string data (3 * 32 = 96 = 0x60)
    final offsetHex = _padUint256(BigInt.from(96));
    // Param 1: fulaPerNft
    final fulaHex = _padUint256(fulaPerNft);
    // Param 2: count
    final countHex = _padUint256(BigInt.from(count));
    // String: length + padded data
    final cidBytes = utf8.encode(ipfsCid);
    final lengthHex = _padUint256(BigInt.from(cidBytes.length));
    final dataHex = _padBytes(cidBytes);

    return '0x$_mintWithFulaSelector$offsetHex$fulaHex$countHex$lengthHex$dataHex';
  }

  /// Encode createClaimOffer(uint256 tokenId, address claimer, uint256 expiresAt)
  String encodeCreateClaimOffer(int tokenId, String claimerAddress, BigInt expiresAt) {
    final tokenHex = _padUint256(BigInt.from(tokenId));
    final address = _padAddress(claimerAddress);
    final expiresHex = _padUint256(expiresAt);
    return '0x$_createClaimOfferSelector$tokenHex$address$expiresHex';
  }

  /// Encode claimNFT(bytes32 linkHash)
  String encodeClaimNft(String linkHash) {
    final hashHex = linkHash.replaceFirst('0x', '').padLeft(64, '0');
    return '0x$_claimNftSelector$hashHex';
  }

  /// Encode transferBack(uint256 tokenId, address sender, uint256 amount)
  String encodeTransferBack(int tokenId, String senderAddress, int amount) {
    final tokenHex = _padUint256(BigInt.from(tokenId));
    final address = _padAddress(senderAddress);
    final amountHex = _padUint256(BigInt.from(amount));
    return '0x$_transferBackSelector$tokenHex$address$amountHex';
  }

  /// Encode balanceOf(address account, uint256 tokenId) — ERC1155
  String encodeBalanceOf(String account, int tokenId) {
    final address = _padAddress(account);
    final tokenHex = _padUint256(BigInt.from(tokenId));
    return '0x$_balanceOfSelector$address$tokenHex';
  }

  /// Encode getTokenInfo(uint256 tokenId)
  String encodeGetTokenInfo(int tokenId) {
    final tokenHex = _padUint256(BigInt.from(tokenId));
    return '0x$_getTokenInfoSelector$tokenHex';
  }

  /// Encode getClaimOffer(bytes32 linkHash)
  String encodeGetClaimOffer(String linkHash) {
    final hashHex = linkHash.replaceFirst('0x', '').padLeft(64, '0');
    return '0x$_getClaimOfferSelector$hashHex';
  }

  /// Encode getCreatorTokens(address creator)
  String encodeGetCreatorTokens(String creatorAddress) {
    final address = _padAddress(creatorAddress);
    return '0x$_getCreatorTokensSelector$address';
  }

  // ============================================================================
  // RPC CALLS
  // ============================================================================

  /// Execute an eth_call (read-only) on the given chain
  Future<String> ethCall({
    required int chainId,
    required String contractAddress,
    required String data,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null || chain.rpcUrl == null) {
      throw Exception('No RPC URL for chain $chainId');
    }

    final response = await http.post(
      Uri.parse(chain.rpcUrl!),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'method': 'eth_call',
        'params': [
          {
            'to': contractAddress,
            'data': data,
          },
          'latest',
        ],
        'id': 1,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('RPC call failed (${response.statusCode})');
    }

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    if (result.containsKey('error')) {
      throw Exception('RPC error: ${result['error']}');
    }

    return result['result'] as String;
  }

  /// Poll for transaction receipt
  Future<Map<String, dynamic>?> getTransactionReceipt({
    required int chainId,
    required String txHash,
  }) async {
    final chain = SupportedChain.byChainId(chainId);
    if (chain == null || chain.rpcUrl == null) return null;

    final response = await http.post(
      Uri.parse(chain.rpcUrl!),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'jsonrpc': '2.0',
        'method': 'eth_getTransactionReceipt',
        'params': [txHash],
        'id': 1,
      }),
    );

    if (response.statusCode != 200) return null;

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['result'] as Map<String, dynamic>?;
  }

  /// Get ERC1155 balance for an address on a specific token
  Future<BigInt> getBalance({
    required int chainId,
    required String contractAddress,
    required String account,
    required int tokenId,
  }) async {
    final data = encodeBalanceOf(account, tokenId);
    final result = await ethCall(
      chainId: chainId,
      contractAddress: contractAddress,
      data: data,
    );

    // Decode uint256 result
    final hex = result.replaceFirst('0x', '');
    if (hex.isEmpty || hex == '0' * 64) return BigInt.zero;
    return BigInt.parse(hex, radix: 16);
  }

  // ============================================================================
  // HELPERS
  // ============================================================================

  /// Pad address to 32 bytes (remove 0x prefix, left-pad to 64 chars)
  String _padAddress(String address) {
    return address.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
  }

  /// Pad uint256 to 32 bytes
  String _padUint256(BigInt value) {
    return value.toRadixString(16).padLeft(64, '0');
  }

  /// Pad bytes to 32-byte boundary
  String _padBytes(List<int> bytes) {
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    // Pad to next 32-byte boundary
    final paddedLength = ((hex.length + 63) ~/ 64) * 64;
    return hex.padRight(paddedLength, '0');
  }
}
