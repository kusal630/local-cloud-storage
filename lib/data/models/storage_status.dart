import 'package:equatable/equatable.dart';

/// Storage usage report shown in Host Dashboard and Storage screens.
class StorageStatus extends Equatable {
  const StorageStatus({
    required this.total,
    required this.free,
    required this.used,
    required this.vaultUsage,
    required this.trashUsage,
  });

  final int total;
  final int free;
  final int used;

  /// Sum of non-trashed file sizes tracked by the vault.
  final int vaultUsage;

  /// Sum of trashed file sizes tracked by the vault.
  final int trashUsage;

  double get usedFraction =>
      total <= 0 ? 0 : (used / total).clamp(0.0, 1.0);

  double get vaultFraction =>
      total <= 0 ? 0 : (vaultUsage / total).clamp(0.0, 1.0);

  @override
  List<Object?> get props => [total, free, used, vaultUsage, trashUsage];
}

/// Response of POST /api/v1/pairing/start.
class PairingInfo extends Equatable {
  const PairingInfo({required this.code, required this.expiresAt});

  final String code;
  final DateTime expiresAt;

  @override
  List<Object?> get props => [code, expiresAt];
}