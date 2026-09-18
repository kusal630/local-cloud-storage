import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';

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
    // Mirror the session's trust settings for the probe.
    try {
      final host = Uri.parse(serverUrl).host;
      final pin = await api.session.getCertPin(host);
      final adapter = dio.httpClientAdapter;
      if (adapter is IOHttpClientAdapter) {
        adapter.createHttpClient = () {
          final client = HttpClient();
          client.badCertificateCallback = (cert, h, p) {
            if (pin != null && pin.isNotEmpty) {
              try {
                return sha256.convert(cert.der).toString() == pin;
              } catch (_) {
                return false;
              }
            }
            return false;
          };
          return client;
        };
      }
    } catch (_) {}
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

  static String hostKeyOf(String serverUrl) {
    try {
      final uri = Uri.parse(serverUrl);
      return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
    } catch (_) {
      return serverUrl;
    }
  }

  /// Applies the saved certificate pin (if any) for [serverUrl].
  Future<void> applySavedPin(String serverUrl) async {
    try {
      final uri = Uri.parse(serverUrl);
      final pin = await api.session.getCertPin(uri.host) ??
          await api.session.getCertPin(hostKeyOf(serverUrl));
      api.setPinnedFingerprint(pin);
    } catch (_) {}
  }

  /// Fetches the SHA-256 fingerprint of the TLS certificate at [serverUrl]
  /// (trust-all, one shot — caller must show it to the user for approval).
  static Future<String> fetchFingerprint(String serverUrl) async {
    final uri = Uri.parse(serverUrl);
    final port = uri.hasPort ? uri.port : 443;
    final socket = await SecureSocket.connect(
      uri.host,
      port,
      timeout: const Duration(seconds: 8),
      onBadCertificate: (_) => true,
    );
    try {
      final cert = socket.peerCertificate;
      if (cert == null) throw const NetworkException('No certificate.');
      return sha256.convert(cert.der).toString();
    } finally {
      socket.destroy();
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
    await applySavedPin(serverUrl);
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

  /// Logs in with username + host password (alternative to pairing).
  Future<void> login({
    required String serverUrl,
    required String username,
    required String password,
    required String deviceName,
  }) async {
    await checkHealth(serverUrl);
    api.configure(serverUrl);
    await applySavedPin(serverUrl);
    try {
      final response = await api.dio.post(
        '/auth/login',
        data: {
          'username': username,
          'password': password,
          'deviceName': deviceName
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