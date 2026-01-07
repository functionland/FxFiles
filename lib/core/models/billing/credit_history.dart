import 'package:equatable/equatable.dart';

enum CreditTransactionType {
  deposit,
  purchase,
  usage,
  withdrawal,
  refund,
  bonus,
  adjustment,
  unknown;

  static CreditTransactionType fromString(String? value) {
    switch (value?.toLowerCase()) {
      case 'deposit':
        return CreditTransactionType.deposit;
      case 'purchase':
        return CreditTransactionType.purchase;
      case 'usage':
        return CreditTransactionType.usage;
      case 'withdrawal':
        return CreditTransactionType.withdrawal;
      case 'refund':
        return CreditTransactionType.refund;
      case 'bonus':
        return CreditTransactionType.bonus;
      case 'adjustment':
        return CreditTransactionType.adjustment;
      default:
        return CreditTransactionType.unknown;
    }
  }

  String get displayName {
    switch (this) {
      case CreditTransactionType.deposit:
        return 'Credit Deposit';
      case CreditTransactionType.purchase:
        return 'Credit Purchase';
      case CreditTransactionType.usage:
        return 'Storage Usage';
      case CreditTransactionType.withdrawal:
        return 'Withdrawal';
      case CreditTransactionType.refund:
        return 'Refund';
      case CreditTransactionType.bonus:
        return 'Bonus Credits';
      case CreditTransactionType.adjustment:
        return 'Adjustment';
      case CreditTransactionType.unknown:
        return 'Transaction';
    }
  }

  bool get isCredit {
    switch (this) {
      case CreditTransactionType.deposit:
      case CreditTransactionType.purchase:
      case CreditTransactionType.refund:
      case CreditTransactionType.bonus:
        return true;
      case CreditTransactionType.usage:
      case CreditTransactionType.withdrawal:
      case CreditTransactionType.adjustment:
      case CreditTransactionType.unknown:
        return false;
    }
  }
}

class CreditHistoryEntry extends Equatable {
  final String id;
  final CreditTransactionType txType;
  final double amountFula;
  final double balanceAfter;
  final String? referenceId;
  final String? description;
  final DateTime createdAt;

  const CreditHistoryEntry({
    required this.id,
    required this.txType,
    required this.amountFula,
    required this.balanceAfter,
    this.referenceId,
    this.description,
    required this.createdAt,
  });

  factory CreditHistoryEntry.fromJson(Map<String, dynamic> json) {
    final referenceId = json['referenceId'] as String? ?? json['reference_id'] as String?;
    return CreditHistoryEntry(
      id: json['id'] as String? ?? referenceId ?? '',
      txType: CreditTransactionType.fromString(
          json['txType'] as String? ?? json['tx_type'] as String?),
      amountFula: _parseDouble(json['amountFula'] ?? json['amount_fula']),
      balanceAfter: _parseDouble(json['balanceAfter'] ?? json['balance_after']),
      referenceId: referenceId,
      description: json['description'] as String?,
      createdAt: DateTime.tryParse(
              json['createdAt'] as String? ?? json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  static double _parseDouble(dynamic value) {
    if (value == null) return 0.0;
    if (value is double) return value;
    if (value is int) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'txType': txType.name,
      'amountFula': amountFula,
      'balanceAfter': balanceAfter,
      'referenceId': referenceId,
      'description': description,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  String get formattedAmount {
    final prefix = txType.isCredit ? '+' : '-';
    return '$prefix${amountFula.toStringAsFixed(2)} FULA';
  }

  @override
  List<Object?> get props => [
        id,
        txType,
        amountFula,
        balanceAfter,
        referenceId,
        description,
        createdAt,
      ];
}

class CreditHistoryPage extends Equatable {
  final List<CreditHistoryEntry> entries;
  final int page;
  final int limit;
  final int totalCount;
  final bool hasMore;

  const CreditHistoryPage({
    required this.entries,
    required this.page,
    required this.limit,
    required this.totalCount,
    required this.hasMore,
  });

  factory CreditHistoryPage.fromJson(Map<String, dynamic> json) {
    final entriesJson = json['history'] as List<dynamic>? ??
        json['entries'] as List<dynamic>? ??
        json['data'] as List<dynamic>? ??
        json['items'] as List<dynamic>? ??
        [];

    final page = json['page'] as int? ?? 1;
    final limit = json['limit'] as int? ?? json['pageSize'] as int? ?? 20;
    final totalCount = json['totalCount'] as int? ?? json['total'] as int? ?? 0;
    final totalPages = json['totalPages'] as int? ?? json['total_pages'] as int? ?? 1;

    // Calculate hasMore from page/totalPages if not explicitly provided
    final hasMore = json['hasMore'] as bool? ??
        json['has_more'] as bool? ??
        (page < totalPages);

    return CreditHistoryPage(
      entries: entriesJson
          .map((e) => CreditHistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      page: page,
      limit: limit,
      totalCount: totalCount,
      hasMore: hasMore,
    );
  }

  factory CreditHistoryPage.empty() {
    return const CreditHistoryPage(
      entries: [],
      page: 1,
      limit: 20,
      totalCount: 0,
      hasMore: false,
    );
  }

  int get totalPages => (totalCount / limit).ceil();

  @override
  List<Object?> get props => [entries, page, limit, totalCount, hasMore];
}
