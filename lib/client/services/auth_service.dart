import 'package:dio/dio.dart';

import '../../core/errors/app_exceptions.dart';
import '../api_client.dart';
import '../auth_interceptor.dart';

/// Authentication and discovery calls against a Host server.
class AuthService {
  AuthService(this.api);

  final LocalVaultApi api;

  /// Validates that a server is reachable at [serverUrl].
  Future<void> checkHealth(String serverUrl) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 5),
    ));
    try {
      final response = await dio.get('/health');
      if (response.statusCode != 200) {
        throw const NetworkException('Server did not respond correctly.');
      }
    } on DioException catch (e) {
      throw NetworkException(
        'Could not reach the host. Verify the URL and that the host server '
        'is running.',
        cause: e,
      );
    } finally {
      dio.close();
    }
  }

  /// Pairs a new device using a short-lived 6-digit code.
  Future<void> pair({
    required String serverUrl,
    required String pairingCode,
    required String deviceName,
  }) async {
    await checkHealth(serverUrl);
    api.configure(serverUrl);
    try {
      final response = await api.dio.post(
        '/pair',
        data: {
          'pairingCode': pairingCode.trim(),
          'deviceName': deviceName,
        },
      );
      final data = LocalVaultApi.decodeData(response);
      final access = data['accessToken'] as String;
      final refresh = data['refreshToken'] as String;
      final deviceId = (data['device'] as Map<String, dynamic>)['id'] as String;
      await api.session.saveTokens(
        accessToken: access,
        refreshToken: refresh,
        deviceId: deviceId,
      );
      await api.session.saveConnection(
        serverUrl: serverUrl,
        deviceName: deviceName,
      );
      _prime(access);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// Logs in with the host password (alternative to pairing).
  Future<void> login({
    required String serverUrl,
    required String password,
    required String deviceName,
  }) async {
    await checkHealth(serverUrl);
    api.configure(serverUrl);
    try {
      final response = await api.dio.post(
        '/auth/login',
        data: {'password': password, 'deviceName': deviceName},
      );
      final data = LocalVaultApi.decodeData(response);
      final access = data['accessToken'] as String;
      final refresh = data['refreshToken'] as String;
      final deviceId = (data['device'] as Map<String, dynamic>)['id'] as String;
      await api.session.saveTokens(
        accessToken: access,
        refreshToken: refresh,
        deviceId: deviceId,
      );
      await api.session.saveConnection(
        serverUrl: serverUrl,
        deviceName: deviceName,
      );
      _prime(access);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// Logs out the current device on the server and clears the local session.
  Future<void> logout() async {
    try {
      await api.dio.post('/auth/logout');
    } catch (_) {
      // best-effort; local session is cleared regardless
    }
    await api.clearSession();
  }

  void _prime(String accessToken) {
    final dio = api.dio;
    for (final interceptor in dio.interceptors) {
      if (interceptor is AuthInterceptor) {
        interceptor.primeToken(accessToken);
      }
    }
  }
}