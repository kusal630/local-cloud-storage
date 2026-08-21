import 'package:equatable/equatable.dart';

/// A paired/connected device known to the host.
class Device extends Equatable {
  const Device({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastSeenAt,
    this.isCurrent = false,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? lastSeenAt;
  final bool isCurrent;

  @override
  List<Object?> get props => [id, name, createdAt, lastSeenAt, isCurrent];
}

/// Tokens returned by login/pairing/refresh.
class AuthTokens extends Equatable {
  const AuthTokens({
    required this.accessToken,
    required this.refreshToken,
    required this.deviceId,
    required this.deviceName,
  });

  final String accessToken;
  final String refreshToken;
  final String deviceId;
  final String deviceName;

  @override
  List<Object?> get props => [accessToken, refreshToken, deviceId, deviceName];
}