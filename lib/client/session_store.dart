import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the active client session.
///
/// Tokens are stored in the platform keystore; the server URL, device name and
/// last session flag are stored in shared preferences.
class SessionStore {
  SessionStore({
    FlutterSecureStorage? secureStorage,
    SharedPreferences? preferences,
  })  : _secure = secureStorage ?? const FlutterSecureStorage(),
        _prefs = preferences;

  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  static const _kAccessToken = 'access_token';
  static const _kRefreshToken = 'refresh_token';
  static const _kDeviceId = 'device_id';
  static const _kServerUrl = 'server_url';
  static const _kDeviceName = 'device_name';

  Future<SharedPreferences> get _shared async =>
      _prefs ??= await SharedPreferences.getInstance();

  // ---------------------------------------------------------------------------
  // Tokens (secure storage)
  // ---------------------------------------------------------------------------

  Future<String?> getAccessToken() => _secure.read(key: _kAccessToken);

  Future<String?> getRefreshToken() => _secure.read(key: _kRefreshToken);

  Future<String?> getDeviceId() => _secure.read(key: _kDeviceId);

  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required String deviceId,
  }) async {
    await _secure.write(key: _kAccessToken, value: accessToken);
    await _secure.write(key: _kRefreshToken, value: refreshToken);
    await _secure.write(key: _kDeviceId, value: deviceId);
  }

  Future<void> clearTokens() async {
    await _secure.delete(key: _kAccessToken);
    await _secure.delete(key: _kRefreshToken);
    await _secure.delete(key: _kDeviceId);
  }

  // ---------------------------------------------------------------------------
  // Connection settings (shared preferences)
  // ---------------------------------------------------------------------------

  Future<String?> getServerUrl() async =>
      (await _shared).getString(_kServerUrl);

  Future<String?> getDeviceName() async =>
      (await _shared).getString(_kDeviceName);

  Future<void> saveConnection({
    required String serverUrl,
    required String deviceName,
  }) async {
    final prefs = await _shared;
    await prefs.setString(_kServerUrl, serverUrl);
    await prefs.setString(_kDeviceName, deviceName);
  }

  Future<void> clearConnection() async {
    final prefs = await _shared;
    await prefs.remove(_kServerUrl);
    await prefs.remove(_kDeviceName);
  }
}