import 'package:equatable/equatable.dart';

class StorageInfo extends Equatable {
  final int currentStorageBytes;
  final int freeTierBytes;
  final int paidStorageBytes;
  final double balanceFula;
  final double usedCredits;
  final double totalCredits;

  /// Lifetime FULA deposited from the blockchain. Excludes referral
  /// bonuses, which the backend accrues to a separate counter.
  final double totalDeposited;

  /// Lifetime FULA consumed by storage, as a POSITIVE number.
  final double totalDeducted;

  /// FULA consumed by storage over the trailing 12 months, as a POSITIVE
  /// number. This — not [totalDeducted] — is the "tokens used" half of the
  /// user's status score; see `user_rank.dart`.
  ///
  /// DEFAULTS TO 0 when the backend does not send it, which makes a
  /// too-old server degrade to ranking on holdings alone rather than
  /// throwing. That is the intended failure mode: a slightly low tier,
  /// never a missing badge or a crash.
  final double deductedLast12Months;

  const StorageInfo({
    required this.currentStorageBytes,
    required this.freeTierBytes,
    required this.paidStorageBytes,
    required this.balanceFula,
    required this.usedCredits,
    required this.totalCredits,
    // Defaulted, not required: these arrived after the model shipped, and
    // every existing construction site (and test) predates them.
    this.totalDeposited = 0,
    this.totalDeducted = 0,
    this.deductedLast12Months = 0,
  });

  factory StorageInfo.fromJson(Map<String, dynamic> json) {
    return StorageInfo(
      currentStorageBytes: _parseInt(json['currentStorageBytes'] ?? json['current_storage_bytes']),
      freeTierBytes: _parseInt(json['freeTierBytes'] ?? json['free_tier_bytes']),
      paidStorageBytes: _parseInt(json['paidStorageBytes'] ?? json['paid_storage_bytes']),
      balanceFula: _parseDouble(json['balanceFula'] ?? json['balance_fula']),
      usedCredits: _parseDouble(json['usedCredits'] ?? json['used_credits']),
      totalCredits: _parseDouble(json['totalCredits'] ?? json['total_credits']),
      totalDeposited:
          _parseDouble(json['totalDeposited'] ?? json['total_deposited']),
      totalDeducted:
          _parseDouble(json['totalDeducted'] ?? json['total_deducted']),
      deductedLast12Months: _parseDouble(json['deductedFulaLast12Months'] ??
          json['deducted_fula_last_12_months']),
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 0;
    if (value is int) return value;
    if (value is double) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    return 0;
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
      'currentStorageBytes': currentStorageBytes,
      'freeTierBytes': freeTierBytes,
      'paidStorageBytes': paidStorageBytes,
      'balanceFula': balanceFula,
      'usedCredits': usedCredits,
      'totalCredits': totalCredits,
      'totalDeposited': totalDeposited,
      'totalDeducted': totalDeducted,
      'deductedFulaLast12Months': deductedLast12Months,
    };
  }

  /// Total available storage in bytes (free tier + paid)
  int get totalAvailableBytes => freeTierBytes + paidStorageBytes;

  /// Remaining storage in bytes
  int get remainingBytes => totalAvailableBytes - currentStorageBytes;

  /// Usage percentage (0.0 to 1.0)
  double get usagePercentage {
    if (totalAvailableBytes == 0) return 0.0;
    return currentStorageBytes / totalAvailableBytes;
  }

  /// Remaining credits
  double get remainingCredits => totalCredits - usedCredits;

  /// Credit usage percentage (0.0 to 1.0)
  double get creditUsagePercentage {
    if (totalCredits == 0) return 0.0;
    return usedCredits / totalCredits;
  }

  /// Whether storage is low (less than 100MB remaining)
  bool get isLowStorage => remainingBytes < 104857600; // 100MB

  /// Format bytes to human readable string
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  String get formattedCurrentStorage => formatBytes(currentStorageBytes);
  String get formattedTotalStorage => formatBytes(totalAvailableBytes);
  String get formattedRemainingStorage => formatBytes(remainingBytes);

  @override
  List<Object?> get props => [
        currentStorageBytes,
        freeTierBytes,
        paidStorageBytes,
        balanceFula,
        usedCredits,
        totalCredits,
        totalDeposited,
        totalDeducted,
        deductedLast12Months,
      ];
}
