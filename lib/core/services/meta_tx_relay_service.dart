import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:fula_files/core/models/billing/supported_chain.dart';
import 'package:fula_files/core/services/nft_contract_service.dart';

/// Relay client for gasless meta-tx claims on Base.
///
/// The creator deposits ETH when creating a claim offer. The relay submits
/// the meta-tx on behalf of the claimer and is reimbursed from the deposit.
class MetaTxRelayService {
  MetaTxRelayService._();
  static final MetaTxRelayService instance = MetaTxRelayService._();

  static const String _relayUrl = 'https://cloud.fx.land/api/v1/nft/relay';
  static const Duration _timeout = Duration(seconds: 30);

  /// Check if a claim link has a gas deposit (indicating gasless is available).
  Future<BigInt> getGasDeposit({
    required int chainId,
    required String linkHash,
  }) async {
    final contract = NftContractService.instance;
    // claimGasDeposits(bytes32) — public mapping getter
    // selector: keccak256("claimGasDeposits(bytes32)")[:4]
    const selector = '6e3e2fa3';
    final hashHex = linkHash.replaceFirst('0x', '').padLeft(64, '0');
    final data = '0x$selector$hashHex';

    final chain = SupportedChain.byChainId(chainId);
    if (chain?.nftContractAddress == null) return BigInt.zero;

    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: chain!.nftContractAddress!,
        data: data,
      );
      final hex = result.replaceFirst('0x', '');
      if (hex.isEmpty || hex.length < 64) return BigInt.zero;
      return BigInt.parse(hex.substring(0, 64), radix: 16);
    } catch (e) {
      debugPrint('MetaTxRelayService: getGasDeposit error: $e');
      return BigInt.zero;
    }
  }

  /// Get the meta-tx nonce for a signer address from the contract.
  Future<int> getMetaNonce({
    required int chainId,
    required String address,
  }) async {
    final contract = NftContractService.instance;
    // metaNonces(address) — public mapping getter
    const selector = 'a3c573eb';
    final addrHex = address.toLowerCase().replaceFirst('0x', '').padLeft(64, '0');
    final data = '0x$selector$addrHex';

    final chain = SupportedChain.byChainId(chainId);
    if (chain?.nftContractAddress == null) return 0;

    try {
      final result = await contract.ethCall(
        chainId: chainId,
        contractAddress: chain!.nftContractAddress!,
        data: data,
      );
      return contract.decodeUint256(result) ?? 0;
    } catch (e) {
      debugPrint('MetaTxRelayService: getMetaNonce error: $e');
      return 0;
    }
  }

  /// Submit a meta-transaction via the relay.
  /// For claim actions: pass [secret] (the raw preimage). The relay passes it to claimNFTMeta.
  /// For burn/transferBack: pass [claimKey] (the public identifier).
  /// Returns the transaction hash.
  Future<String> relay({
    required String action,
    required int chainId,
    String? secret,
    String? claimKey,
    required String signer,
    required int deadline,
    required int nonce,
    required String signature,
    int? tokenId,
    int? amount,
  }) async {
    final body = <String, dynamic>{
      'action': action,
      'chainId': chainId,
      'signer': signer,
      'deadline': deadline,
      'nonce': nonce,
      'signature': signature,
    };
    // For claim: send secret (relay needs it for claimNFTMeta) and claimKey (for gas deposit lookup)
    if (secret != null) body['secret'] = secret;
    if (claimKey != null) body['claimKey'] = claimKey;
    if (tokenId != null) body['tokenId'] = tokenId;
    if (amount != null) body['amount'] = amount;

    final response = await http.post(
      Uri.parse(_relayUrl),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    ).timeout(_timeout);

    final result = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200 || result['success'] != true) {
      final error = result['error'] ?? 'Relay failed (${response.statusCode})';
      throw Exception(error);
    }

    return result['txHash'] as String;
  }
}
