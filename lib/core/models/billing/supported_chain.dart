import 'package:equatable/equatable.dart';

class SupportedChain extends Equatable {
  final int chainId;
  final String chainName;
  final String tokenAddress;
  final String? vaultAddress;
  final String? rpcUrl;
  final String? explorerUrl;
  final int decimals;

  const SupportedChain({
    required this.chainId,
    required this.chainName,
    required this.tokenAddress,
    this.vaultAddress,
    this.rpcUrl,
    this.explorerUrl,
    this.decimals = 18,
  });

  /// Fixed vault address for all chains
  static const defaultVaultAddress = '0x83dF763874934Cc72C309dA5566eA2AFB6eE4f4e';

  /// Base mainnet chain configuration
  static const base = SupportedChain(
    chainId: 8453,
    chainName: 'Base',
    tokenAddress: '0x9e12735d77c72c5C3670636D428f2F3815d8A4cB',
    vaultAddress: defaultVaultAddress,
    rpcUrl: 'https://mainnet.base.org',
    explorerUrl: 'https://basescan.org',
    decimals: 18,
  );

  /// Skale Europa chain configuration
  static const skale = SupportedChain(
    chainId: 2046399126,
    chainName: 'Skale Europa',
    tokenAddress: '0x9e12735d77c72c5C3670636D428f2F3815d8A4cB',
    vaultAddress: defaultVaultAddress,
    rpcUrl: 'https://mainnet.skalenodes.com/v1/elated-tan-skat',
    explorerUrl: 'https://elated-tan-skat.explorer.mainnet.skalenodes.com',
    decimals: 18,
  );

  /// All supported chains
  static const List<SupportedChain> all = [base, skale];

  /// Get chain by ID
  static SupportedChain? byChainId(int chainId) {
    for (final chain in all) {
      if (chain.chainId == chainId) return chain;
    }
    return null;
  }

  factory SupportedChain.fromJson(Map<String, dynamic> json) {
    return SupportedChain(
      chainId: json['chainId'] as int? ?? json['chain_id'] as int? ?? 0,
      chainName: json['chainName'] as String? ?? json['chain_name'] as String? ?? '',
      tokenAddress: json['tokenAddress'] as String? ?? json['token_address'] as String? ?? '',
      vaultAddress: json['vaultAddress'] as String? ?? json['vault_address'] as String?,
      rpcUrl: json['rpcUrl'] as String? ?? json['rpc_url'] as String?,
      explorerUrl: json['explorerUrl'] as String? ?? json['explorer_url'] as String?,
      decimals: json['decimals'] as int? ?? 18,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'chainId': chainId,
      'chainName': chainName,
      'tokenAddress': tokenAddress,
      'vaultAddress': vaultAddress,
      'rpcUrl': rpcUrl,
      'explorerUrl': explorerUrl,
      'decimals': decimals,
    };
  }

  /// Copy with vault address from API
  SupportedChain withVaultAddress(String vault) {
    return SupportedChain(
      chainId: chainId,
      chainName: chainName,
      tokenAddress: tokenAddress,
      vaultAddress: vault,
      rpcUrl: rpcUrl,
      explorerUrl: explorerUrl,
      decimals: decimals,
    );
  }

  /// Get explorer URL for a transaction
  String? getTxExplorerUrl(String txHash) {
    if (explorerUrl == null) return null;
    return '$explorerUrl/tx/$txHash';
  }

  /// Get explorer URL for an address
  String? getAddressExplorerUrl(String address) {
    if (explorerUrl == null) return null;
    return '$explorerUrl/address/$address';
  }

  @override
  List<Object?> get props => [
        chainId,
        chainName,
        tokenAddress,
        vaultAddress,
        rpcUrl,
        explorerUrl,
        decimals,
      ];
}
