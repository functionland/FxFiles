import 'package:equatable/equatable.dart';

class WalletInfo extends Equatable {
  final String address;
  final int chainId;
  final bool isVerified;
  final DateTime? connectedAt;

  const WalletInfo({
    required this.address,
    required this.chainId,
    this.isVerified = false,
    this.connectedAt,
  });

  factory WalletInfo.fromJson(Map<String, dynamic> json) {
    return WalletInfo(
      address: json['address'] as String? ?? '',
      chainId: _parseInt(json['chainId'] ?? json['chain_id']),
      isVerified: _parseBool(json['isVerified'] ?? json['is_verified']),
      connectedAt: json['connectedAt'] != null
          ? DateTime.tryParse(json['connectedAt'] as String)
          : json['connected_at'] != null
              ? DateTime.tryParse(json['connected_at'] as String)
              : null,
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
  }

  static bool _parseBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is String) return value.toLowerCase() == 'true' || value == '1';
    return false;
  }

  Map<String, dynamic> toJson() {
    return {
      'address': address,
      'chainId': chainId,
      'isVerified': isVerified,
      'connectedAt': connectedAt?.toIso8601String(),
    };
  }

  String get shortAddress {
    if (address.length <= 10) return address;
    return '${address.substring(0, 6)}...${address.substring(address.length - 4)}';
  }

  @override
  List<Object?> get props => [address, chainId, isVerified, connectedAt];
}
