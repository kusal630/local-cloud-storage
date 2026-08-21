import 'package:dio/dio.dart';

import '../core/errors/app_exceptions.dart';
import '../core/logging/app_logger.dart';
import 'auth_interceptor.dart';
import 'session_store.dart';

/// The Dio-powered HTTP client used in Client Mode.
///
/// All requests go through [AuthInterceptor] which attaches the bearer token
/// and transparently refreshes expired access tokens.
class LocalVaultApi {
  LocalVaultApi({
    required this.session,
    Dio? dio,
    void Function()? onAuthFailure,
  }) {
    _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 10)));
    _dio.interceptors.add(
      AuthInterceptor(
        dio: _dio,
        session: session,
        refresh: refreshAccessToken,
        onAuthFailure: onAuthFailure ?? () {},
      ),
    );
  }

  final SessionStore session;
  late final Dio _dio;

  String? _serverUrl;

  String? get serverUrl => _serverUrl;

  /// Configures the base URL. Expected format: `http://host:port`.
  void configure(String serverUrl) {
    _serverUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
    _dio.options.baseUrl = '$_serverUrl/api/v1';
  }

  Dio get dio => _dio;

  /// Refreshes the access token using the stored refresh token.
  ///
  /// Returns true on success. Single-flight: concurrent callers share one
  /// refresh request.
  Future<bool> refreshAccessToken() async {
    final refreshToken = await session.getRefreshToken();
    if (refreshToken == null || refreshToken.isEmpty) return false;
    try {
      final response = await _dio.post(
        '/auth/refresh',
        data: {'refreshToken': refreshToken},
        options: Options(
          headers: {
            'Authorization': '',
            AuthInterceptor.retriedHeader: '1',
          },
        ),
      );
      final data = response.data as Map<String, dynamic>;
      final access = data['accessToken'] as String;
      final newRefresh = data['refreshToken'] as String;
      final deviceId = (data['device'] as Map<String, dynamic>)['id'] as String;
      await session.saveTokens(
        accessToken: access,
        refreshToken: newRefresh,
        deviceId: deviceId,
      );
      _prime(access);
      return true;
    } on DioException catch (e) {
      logError('Token refresh failed', e);
      return false;
    }
  }

  void _prime(String accessToken) {
    for (final interceptor in _dio.interceptors) {
      if (interceptor is AuthInterceptor) {
        interceptor.primeToken(accessToken);
      }
    }
  }

  /// Clears the in-memory token and stored session.
  Future<void> clearSession() async {
    for (final interceptor in _dio.interceptors) {
      if (interceptor is AuthInterceptor) {
        interceptor.invalidateToken();
      }
    }
    await session.clearTokens();
    await session.clearConnection();
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Decodes a successful JSON envelope. Throws [ApiException] on failure.
  static Map<String, dynamic> decodeData(Response<dynamic> response,
      {String dataKey = 'data'}) {
    final body = response.data;
    if (body is! Map<String, dynamic>) {
      throw const ApiException(500, 'Malformed server response.');
    }
    if (body['ok'] != true) {
      final error = body['error'];
      if (error is Map<String, dynamic>) {
        throw ApiException(
          response.statusCode ?? 500,
          error['message']?.toString() ?? 'Unknown server error.',
        );
      }
      throw ApiException(
        response.statusCode ?? 500,
        'Unknown server error.',
      );
    }
    return body;
  }

  /// Converts a DioException into a typed [AppException].
  static AppException mapError(Object error) {
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.connectionError:
          return NetworkException(
            'Could not reach the host. Check that it is running and '
            'you are on the same network.',
            cause: error,
          );
        case DioExceptionType.badResponse:
          final status = error.response?.statusCode ?? 500;
          final data = error.response?.data;
          String message = 'Server error ($status).';
          if (data is Map && data['error'] is Map) {
            final e = data['error'] as Map;
            message = e['message']?.toString() ?? message;
          }
          if (status == 401) {
            return const AuthException('Session expired. Please connect again.');
          }
          return ApiException(status, message, cause: error);
        case DioExceptionType.cancel:
          return const NetworkException('Transfer cancelled.');
        default:
          return NetworkException('Unexpected network error.', cause: error);
      }
    }
    return error is AppException
        ? error
        : NetworkException('Unexpected error.', cause: error);
  }
}