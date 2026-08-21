import 'package:dio/dio.dart';

import 'session_store.dart';

/// Queued interceptor that attaches the bearer token and transparently refreshes
/// it once when a request fails with 401.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this.dio,
    required this.session,
    required this.refresh,
    required this.onAuthFailure,
  });

  final Dio dio;
  final SessionStore session;
  final Future<bool> Function() refresh;
  final void Function() onAuthFailure;

  static const retriedHeader = 'X-LocalVault-Retried';

  String? _cachedAccessToken;

  void primeToken(String token) {
    _cachedAccessToken = token;
  }

  void invalidateToken() {
    _cachedAccessToken = null;
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _cachedAccessToken;
    if (token != null && token.isNotEmpty) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final status = err.response?.statusCode;
    final alreadyRetried = err.requestOptions.headers[retriedHeader] == '1';

    if (status == 401 && !alreadyRetried) {
      try {
        final refreshed = await refresh();
        if (refreshed) {
          final opts = err.requestOptions;
          opts.headers['Authorization'] = 'Bearer $_cachedAccessToken';
          opts.headers[retriedHeader] = '1';
          final response = await dio.fetch(opts);
          return handler.resolve(response);
        }
      } catch (_) {
        // fall through
      }
      onAuthFailure();
    }
    handler.next(err);
  }
}