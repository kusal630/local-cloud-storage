import '../../core/constants/app_constants.dart';
import '../../core/utils/cipher.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/device.dart';

/// Issues and refreshes bearer tokens.
///
/// Only SHA-256 hashes of tokens are ever persisted. The plaintext token is
/// returned to the client exactly once.
class TokenService {
  TokenService(this.vault);

  final Vault vault;

  /// Creates a brand new device with a fresh access + refresh token pair.
  AuthTokens createDevice({
    required String deviceId,
    required String deviceName,
    bool isCurrent = false,
  }) {
    final accessToken = Cipher.randomHex(32);
    final refreshToken = Cipher.randomHex(32);
    final now = DateTime.now();
    vault.devices.create(
      id: deviceId,
      name: deviceName,
      accessTokenHash: Cipher.sha256String(accessToken),
      accessTokenExpiresAt: now.add(AppConstants.accessTokenLifetime).millisecondsSinceEpoch,
      refreshTokenHash: Cipher.sha256String(refreshToken),
      refreshTokenExpiresAt: now.add(AppConstants.refreshTokenLifetime).millisecondsSinceEpoch,
      isCurrent: isCurrent,
    );
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }

  /// Rotates the token pair for [deviceId].
  AuthTokens rotate(String deviceId, String deviceName) {
    final accessToken = Cipher.randomHex(32);
    final refreshToken = Cipher.randomHex(32);
    final now = DateTime.now();
    vault.devices.rotateTokens(
      id: deviceId,
      accessTokenHash: Cipher.sha256String(accessToken),
      accessTokenExpiresAt: now.add(AppConstants.accessTokenLifetime).millisecondsSinceEpoch,
      refreshTokenHash: Cipher.sha256String(refreshToken),
      refreshTokenExpiresAt: now.add(AppConstants.refreshTokenLifetime).millisecondsSinceEpoch,
    );
    return AuthTokens(
      accessToken: accessToken,
      refreshToken: refreshToken,
      deviceId: deviceId,
      deviceName: deviceName,
    );
  }
}