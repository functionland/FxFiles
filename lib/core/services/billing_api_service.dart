import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:fula_files/core/models/billing/billing_models.dart';
import 'package:fula_files/core/services/secure_storage_service.dart';

class BillingApiService {
  static final BillingApiService instance = BillingApiService._();
  BillingApiService._();

  static const String _defaultBillingServer = 'https://cloud.fx.land';

  Future<String?> _getBaseUrl() async {
    final url = await SecureStorageService.instance.read(SecureStorageKeys.billingServerUrl);
    return url?.isNotEmpty == true ? url : _defaultBillingServer;
  }

  Future<String?> _getJwtToken() async {
    return await SecureStorageService.instance.read(SecureStorageKeys.jwtToken);
  }

  Future<Map<String, String>> _getHeaders() async {
    final token = await _getJwtToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
  }

  void _ensureConfigured(String? baseUrl, String? token) {
    if (baseUrl == null || baseUrl.isEmpty) {
      throw BillingApiException('IPFS Pinning Server URL is not configured');
    }
    if (token == null || token.isEmpty) {
      throw BillingApiException('JWT Token is not configured');
    }
  }

  /// Get storage and credit information
  Future<StorageInfo> getStorageAndCredits() async {
    final baseUrl = await _getBaseUrl();
    final token = await _getJwtToken();
    _ensureConfigured(baseUrl, token);

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/v1/storage'),
        headers: await _getHeaders(),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return StorageInfo.fromJson(json);
      } else {
        throw BillingApiException(
          'Failed to get storage info: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      if (e is BillingApiException) rethrow;
      throw BillingApiException('Failed to get storage info: $e');
    }
  }

  /// Get linked wallets and supported chains
  Future<WalletsResponse> getWallets() async {
    final baseUrl = await _getBaseUrl();
    final token = await _getJwtToken();
    _ensureConfigured(baseUrl, token);

    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/v1/wallets'),
        headers: await _getHeaders(),
      );

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return WalletsResponse.fromJson(json);
      } else {
        throw BillingApiException(
          'Failed to get wallets: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      if (e is BillingApiException) rethrow;
      throw BillingApiException('Failed to get wallets: $e');
    }
  }

  /// Link a wallet with signature verification
  Future<bool> linkWallet({
    required String address,
    required int chainId,
    required String signature,
    required String message,
  }) async {
    final baseUrl = await _getBaseUrl();
    final token = await _getJwtToken();
    _ensureConfigured(baseUrl, token);

    try {
      final requestBody = {
        'address': address,
        'chainId': chainId,
        'signature': signature,
        'message': message,
      };
      debugPrint('BillingApiService: linkWallet request body: $requestBody');

      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/wallets/link'),
        headers: await _getHeaders(),
        body: jsonEncode(requestBody),
      );

      debugPrint('BillingApiService: linkWallet response: ${response.statusCode} - ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 201) {
        return true;
      } else {
        final error = _parseError(response.body);
        throw BillingApiException(
          'Failed to link wallet: ${response.statusCode} - $error',
        );
      }
    } catch (e) {
      if (e is BillingApiException) rethrow;
      throw BillingApiException('Failed to link wallet: $e');
    }
  }

  /// Claim credits from a transaction
  Future<ClaimResponse> claimCredits({
    required String txHash,
    required int chainId,
  }) async {
    final baseUrl = await _getBaseUrl();
    final token = await _getJwtToken();
    _ensureConfigured(baseUrl, token);

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/v1/credits/claim'),
        headers: await _getHeaders(),
        body: jsonEncode({
          'txHash': txHash,
          'chainId': chainId,
        }),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return ClaimResponse.fromJson(json);
      } else {
        final error = _parseError(response.body);
        throw BillingApiException(
          'Failed to claim credits: ${response.statusCode} - $error',
        );
      }
    } catch (e) {
      if (e is BillingApiException) rethrow;
      throw BillingApiException('Failed to claim credits: $e');
    }
  }

  /// Get paginated credit history
  Future<CreditHistoryPage> getCreditHistory({
    int page = 1,
    int limit = 20,
  }) async {
    final baseUrl = await _getBaseUrl();
    final token = await _getJwtToken();
    _ensureConfigured(baseUrl, token);

    try {
      final url = '$baseUrl/api/v1/credits/history?page=$page&limit=$limit';
      debugPrint('BillingAPI: GET $url');
      final response = await http.get(
        Uri.parse(url),
        headers: await _getHeaders(),
      );

      debugPrint('BillingAPI: credit history response ${response.statusCode}: ${response.body}');

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return CreditHistoryPage.fromJson(json);
      } else {
        throw BillingApiException(
          'Failed to get credit history: ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e) {
      if (e is BillingApiException) rethrow;
      throw BillingApiException('Failed to get credit history: $e');
    }
  }

  String _parseError(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      return json['error'] as String? ??
          json['message'] as String? ??
          body;
    } catch (_) {
      return body;
    }
  }
}

/// Response from GET /api/v1/wallets
class WalletsResponse {
  final List<WalletInfo> wallets;
  final List<ChainVaultInfo> supportedChains;

  const WalletsResponse({
    required this.wallets,
    required this.supportedChains,
  });

  factory WalletsResponse.fromJson(Map<String, dynamic> json) {
    final walletsJson = json['wallets'] as List<dynamic>? ?? [];
    final chainsJson = json['supportedChains'] as List<dynamic>? ??
        json['supported_chains'] as List<dynamic>? ??
        [];

    return WalletsResponse(
      wallets: walletsJson
          .map((w) => WalletInfo.fromJson(w as Map<String, dynamic>))
          .toList(),
      supportedChains: chainsJson
          .map((c) => ChainVaultInfo.fromJson(c as Map<String, dynamic>))
          .toList(),
    );
  }
}

/// Chain info with vault address from API
class ChainVaultInfo {
  final int chainId;
  final String chainName;
  final String vaultAddress;
  final String tokenAddress;

  const ChainVaultInfo({
    required this.chainId,
    required this.chainName,
    required this.vaultAddress,
    required this.tokenAddress,
  });

  factory ChainVaultInfo.fromJson(Map<String, dynamic> json) {
    return ChainVaultInfo(
      chainId: json['chainId'] as int? ?? json['chain_id'] as int? ?? 0,
      chainName: json['chainName'] as String? ?? json['chain_name'] as String? ?? '',
      vaultAddress: json['vaultAddress'] as String? ?? json['vault_address'] as String? ?? '',
      tokenAddress: json['tokenAddress'] as String? ?? json['token_address'] as String? ?? '',
    );
  }

  /// Get SupportedChain with vault address
  SupportedChain toSupportedChain() {
    final base = SupportedChain.byChainId(chainId);
    if (base != null) {
      return base.withVaultAddress(vaultAddress);
    }
    return SupportedChain(
      chainId: chainId,
      chainName: chainName,
      tokenAddress: tokenAddress,
      vaultAddress: vaultAddress,
    );
  }
}

/// Response from POST /api/v1/credits/claim
class ClaimResponse {
  final bool success;
  final double creditsAdded;
  final double newBalance;
  final String? message;

  const ClaimResponse({
    required this.success,
    required this.creditsAdded,
    required this.newBalance,
    this.message,
  });

  factory ClaimResponse.fromJson(Map<String, dynamic> json) {
    return ClaimResponse(
      success: json['success'] as bool? ?? true,
      creditsAdded: _parseDouble(json['creditsAdded'] ?? json['credits_added']),
      newBalance: _parseDouble(json['newBalance'] ?? json['new_balance']),
      message: json['message'] as String?,
    );
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}

class BillingApiException implements Exception {
  final String message;
  BillingApiException(this.message);

  @override
  String toString() => 'BillingApiException: $message';
}
