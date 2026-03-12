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

  // Function selectors — keccak256 of signature, first 4 bytes
  // mintWithFula(string,string,uint256,uint256)
  static const String _mintWithFulaSelector = '4caf86a6';
  // createClaimOffer(uint256,address,uint256)
  static const String _createClaimOfferSelector = '49db23ce';
  // claimNFT(bytes32)
  static const String _claimNftSelector = 'fbcb5ae7';
  // burn(address,uint256,uint256)
  static const String _burnSelector = 'f5298aca';
  // safeTransferFrom(address,address,uint256,uint256,bytes)
  static const String _safeTransferFromSelector = 'f242432a';
  // balanceOf(address,uint256) — standard ERC1155
  static const String _balanceOfSelector = '00fdd58e';
  // getTokenInfo(uint256)
  static const String _getTokenInfoSelector = '8c7a63ae';
  // getClaimOffer(bytes32)
  static const String _getClaimOfferSelector = '695aaae9';
  // getCreatorEvents(address)
  static const String _getCreatorEventsSelector = 'f82678f2';
  // getEventTokens(address,string,uint256,uint256)
  static const String _getEventTokensSelector = 'a3de9df1';
  // getEventTokenCount(address,string)
  static const String _getEventTokenCountSelector = '69a76991';
  // cancelClaimOffer(bytes32)
  static const String _cancelClaimOfferSelector = '29845de0';
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

  /// Encode mintWithFula(string eventName, string metadataCid, uint256 fulaPerNft, uint256 count)
  String encodeMintWithFula(String eventName, String metadataCid, BigInt fulaPerNft, int count) {
    // ABI encoding for (string, string, uint256, uint256):
    // Head: 4 words. Word 0 = offset to eventName data. Word 1 = offset to metadataCid data.
    // Word 2 = fulaPerNft. Word 3 = count.
    final eventNameBytes = utf8.encode(eventName);
    final metadataCidBytes = utf8.encode(metadataCid);

    // eventName offset = 128 (0x80, past 4 head words)
    final eventNameOffset = _padUint256(BigInt.from(128));
    // metadataCid offset = 128 + 32 + ceil32(eventNameBytes.length)
    final eventNamePaddedLen = ((eventNameBytes.length + 31) ~/ 32) * 32;
    final metadataCidOffset = _padUint256(BigInt.from(128 + 32 + eventNamePaddedLen));
    // fulaPerNft
    final fulaHex = _padUint256(fulaPerNft);
    // count
    final countHex = _padUint256(BigInt.from(count));

    // eventName: length + padded data
    final eventNameLengthHex = _padUint256(BigInt.from(eventNameBytes.length));
    final eventNameDataHex = _padBytes(eventNameBytes);

    // metadataCid: length + padded data
    final metadataCidLengthHex = _padUint256(BigInt.from(metadataCidBytes.length));
    final metadataCidDataHex = _padBytes(metadataCidBytes);

    return '0x$_mintWithFulaSelector'
        '$eventNameOffset$metadataCidOffset$fulaHex$countHex'
        '$eventNameLengthHex$eventNameDataHex'
        '$metadataCidLengthHex$metadataCidDataHex';
  }

  /// Encode createClaimOffer(uint256 tokenId, address claimer, uint256 expiresAt)
  /// If [claimerAddress] is null, uses address(0) for an open claim.
  String encodeCreateClaimOffer(int tokenId, String? claimerAddress, BigInt expiresAt) {
    final tokenHex = _padUint256(BigInt.from(tokenId));
    final address = _padAddress(claimerAddress ?? '0x0000000000000000000000000000000000000000');
    final expiresHex = _padUint256(expiresAt);
    return '0x$_createClaimOfferSelector$tokenHex$address$expiresHex';
  }

  /// Encode claimNFT(bytes32 linkHash)
  String encodeClaimNft(String linkHash) {
    final hashHex = linkHash.replaceFirst('0x', '').padLeft(64, '0');
    return '0x$_claimNftSelector$hashHex';
  }

  /// Encode cancelClaimOffer(bytes32 linkHash)
  String encodeCancelClaimOffer(String linkHash) {
    final hashHex = linkHash.replaceFirst('0x', '').padLeft(64, '0');
    return '0x$_cancelClaimOfferSelector$hashHex';
  }

  /// Encode burn(address account, uint256 id, uint256 value)
  String encodeBurn(String account, int tokenId, int amount) {
    final address = _padAddress(account);
    final tokenHex = _padUint256(BigInt.from(tokenId));
    final amountHex = _padUint256(BigInt.from(amount));
    return '0x$_burnSelector$address$tokenHex$amountHex';
  }

  /// Encode safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data)
  /// Uses empty bytes for data.
  String encodeSafeTransferFrom(String from, String to, int tokenId, int amount) {
    final fromHex = _padAddress(from);
    final toHex = _padAddress(to);
    final tokenHex = _padUint256(BigInt.from(tokenId));
    final amountHex = _padUint256(BigInt.from(amount));
    // data offset = 5 * 32 = 160 = 0xa0
    final offsetHex = _padUint256(BigInt.from(160));
    // data length = 0
    final lengthHex = _padUint256(BigInt.zero);
    return '0x$_safeTransferFromSelector$fromHex$toHex$tokenHex$amountHex$offsetHex$lengthHex';
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

  /// Encode getCreatorEvents(address creator)
  String encodeGetCreatorEvents(String creatorAddress) {
    final address = _padAddress(creatorAddress);
    return '0x$_getCreatorEventsSelector$address';
  }

  /// Encode getEventTokens(address creator, string eventName, uint256 offset, uint256 limit)
  String encodeGetEventTokens(String creatorAddress, String eventName, int offset, int limit) {
    final address = _padAddress(creatorAddress);
    final eventNameBytes = utf8.encode(eventName);

    // Head: 4 words. Word 0 = address. Word 1 = offset to eventName string.
    // Word 2 = offset. Word 3 = limit.
    // eventName string offset = 4 * 32 = 128 (0x80)
    final stringOffset = _padUint256(BigInt.from(128));
    final offsetHex = _padUint256(BigInt.from(offset));
    final limitHex = _padUint256(BigInt.from(limit));

    // eventName: length + padded data
    final eventNameLengthHex = _padUint256(BigInt.from(eventNameBytes.length));
    final eventNameDataHex = _padBytes(eventNameBytes);

    return '0x$_getEventTokensSelector$address$stringOffset$offsetHex$limitHex'
        '$eventNameLengthHex$eventNameDataHex';
  }

  /// Encode getEventTokenCount(address creator, string eventName)
  String encodeGetEventTokenCount(String creatorAddress, String eventName) {
    final address = _padAddress(creatorAddress);
    final eventNameBytes = utf8.encode(eventName);

    // Head: 2 words. Word 0 = address. Word 1 = offset to eventName string.
    // eventName string offset = 2 * 32 = 64 (0x40)
    final stringOffset = _padUint256(BigInt.from(64));

    // eventName: length + padded data
    final eventNameLengthHex = _padUint256(BigInt.from(eventNameBytes.length));
    final eventNameDataHex = _padBytes(eventNameBytes);

    return '0x$_getEventTokenCountSelector$address$stringOffset'
        '$eventNameLengthHex$eventNameDataHex';
  }

  // ============================================================================
  // RPC CALLS
  // ============================================================================

  static const Duration _rpcTimeout = Duration(seconds: 30);

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
    ).timeout(_rpcTimeout);

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
    ).timeout(_rpcTimeout);

    if (response.statusCode != 200) return null;

    final result = jsonDecode(response.body) as Map<String, dynamic>;
    return result['result'] as Map<String, dynamic>?;
  }

  /// Poll for transaction receipt with timeout
  /// Returns the receipt map, or throws on revert or timeout.
  Future<Map<String, dynamic>> pollForReceipt({
    required int chainId,
    required String txHash,
    Duration interval = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final receipt = await getTransactionReceipt(
        chainId: chainId,
        txHash: txHash,
      );

      if (receipt != null) {
        // Check for revert: status '0x0' means failure
        final status = receipt['status'] as String?;
        if (status == '0x0') {
          throw Exception('Transaction reverted: $txHash');
        }
        return receipt;
      }

      await Future.delayed(interval);
    }

    throw Exception('Transaction receipt timeout after ${timeout.inMinutes} minutes: $txHash');
  }

  /// Parse tokenId from an ERC1155 TransferSingle event in a receipt.
  /// TransferSingle topic: 0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62
  /// Event: TransferSingle(address operator, address from, address to, uint256 id, uint256 value)
  /// 'id' is at data[0:64] (first 32 bytes of non-indexed data)
  int? parseTokenIdFromReceipt(Map<String, dynamic> receipt) {
    const transferSingleTopic =
        '0xc3d58168c5ae7397731d063d5bbf3d657854427343f4c083240f7aacaa2d0f62';

    final logs = receipt['logs'] as List<dynamic>?;
    if (logs == null) return null;

    for (final log in logs) {
      final logMap = log as Map<String, dynamic>;
      final topics = logMap['topics'] as List<dynamic>?;
      if (topics == null || topics.isEmpty) continue;

      if (topics[0].toString().toLowerCase() == transferSingleTopic.toLowerCase()) {
        final data = (logMap['data'] as String?)?.replaceFirst('0x', '');
        if (data == null || data.length < 64) continue;

        // First 32 bytes of data = id
        final idHex = data.substring(0, 64);
        return int.tryParse(idHex, radix: 16);
      }
    }

    return null;
  }

  /// Parse linkHash from a ClaimOfferCreated event in a receipt.
  /// ClaimOfferCreated(bytes32 indexed linkHash, uint256 indexed tokenId, address sender, address claimer, uint256 expiresAt)
  /// The linkHash is the first indexed param (topic[1]).
  static const String _claimOfferCreatedTopic =
      '0x71b6a711485badd557a644445bd69c859975a95cbd717cc76c989d7c6a3e0416';

  String? parseClaimOfferHash(Map<String, dynamic> receipt) {
    final logs = receipt['logs'] as List<dynamic>?;
    if (logs == null) return null;

    for (final log in logs) {
      final logMap = log as Map<String, dynamic>;
      final topics = logMap['topics'] as List<dynamic>?;
      if (topics == null || topics.length < 3) continue;

      // Match by actual event signature hash
      if (topics[0].toString().toLowerCase() == _claimOfferCreatedTopic) {
        return topics[1].toString();
      }
    }

    return null;
  }

  /// Decode getTokenInfo response: (address creator, string metadataCid, string eventName, uint256 fulaPerNft, uint256 initialMintCount)
  ({String creator, String metadataCid, String eventName, BigInt fulaPerNft, int initialMintCount})? decodeTokenInfo(String hexData) {
    final data = hexData.replaceFirst('0x', '');
    if (data.length < 320) return null; // Minimum: 5 * 32 bytes

    try {
      // Word 0: creator address (left-padded in 32 bytes)
      final creator = '0x${data.substring(24, 64)}';
      // Word 1: offset to metadataCid string
      final metadataCidOffset = int.parse(data.substring(64, 128), radix: 16) * 2;
      // Word 2: offset to eventName string
      final eventNameOffset = int.parse(data.substring(128, 192), radix: 16) * 2;
      // Word 3: fulaPerNft
      final fulaPerNft = BigInt.parse(data.substring(192, 256), radix: 16);
      // Word 4: initialMintCount
      final initialMintCount = int.parse(data.substring(256, 320), radix: 16);

      // Decode metadataCid string at offset
      final metadataCid = _decodeString(data, metadataCidOffset);
      // Decode eventName string at offset
      final eventName = _decodeString(data, eventNameOffset);

      return (creator: creator, metadataCid: metadataCid, eventName: eventName, fulaPerNft: fulaPerNft, initialMintCount: initialMintCount);
    } catch (e) {
      debugPrint('NftContractService: decodeTokenInfo error: $e');
      return null;
    }
  }

  /// Decode an ABI-encoded string at the given hex offset within data
  String _decodeString(String data, int hexOffset) {
    final lengthHex = data.substring(hexOffset, hexOffset + 64);
    final length = int.parse(lengthHex, radix: 16);
    if (length == 0) return '';
    final stringDataHex = data.substring(hexOffset + 64, hexOffset + 64 + length * 2);
    return String.fromCharCodes(
      List.generate(length, (i) => int.parse(stringDataHex.substring(i * 2, i * 2 + 2), radix: 16)),
    );
  }

  /// Decode getClaimOffer response: (uint256 tokenId, address sender, address claimer, uint256 expiresAt, uint8 status)
  /// Status: 0=active, 1=claimed, 2=cancelled
  ({int tokenId, int status, int expiresAt, String? claimerAddress})? decodeClaimOffer(String hexData) {
    final data = hexData.replaceFirst('0x', '');
    if (data.length < 320) return null; // 5 * 32 bytes

    try {
      // Word 0: tokenId
      final tokenId = int.parse(data.substring(0, 64), radix: 16);
      // Word 1: sender address (skip)
      // Word 2: claimer address
      final claimerRaw = data.substring(128, 192);
      final claimerAddr = '0x${claimerRaw.substring(24)}';
      final claimer = claimerAddr == '0x${'0' * 40}' ? null : claimerAddr;
      // Word 3: expiresAt
      final expiresAt = int.parse(data.substring(192, 256), radix: 16);
      // Word 4: status (uint8: 0=active, 1=claimed, 2=cancelled)
      final status = int.parse(data.substring(256, 320), radix: 16);

      return (tokenId: tokenId, status: status, expiresAt: expiresAt, claimerAddress: claimer);
    } catch (e) {
      debugPrint('NftContractService: decodeClaimOffer error: $e');
      return null;
    }
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
