import 'package:equatable/equatable.dart';

/// One row of the host-side activity log.
class AuditEntry extends Equatable {
  const AuditEntry({
    required this.id,
    this.deviceId,
    required this.action,
    this.targetId,
    this.targetName,
    this.detail,
    required this.createdAt,
  });

  final String id;
  final String? deviceId;
  final String action;
  final String? targetId;
  final String? targetName;
  final String? detail;
  final DateTime createdAt;

  @override
  List<Object?> get props =>
      [id, deviceId, action, targetId, targetName, detail, createdAt];
}
