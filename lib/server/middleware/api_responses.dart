import 'dart:convert';

import 'package:shelf/shelf.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';

/// JSON helpers and centralized error mapping for the REST API.
abstract class ApiResponses {
  ApiResponses._();

  static const Map<String, String> _jsonHeaders = {
    'content-type': 'application/json; charset=utf-8',
  };

  static Response ok([Map<String, Object?>? data]) {
    final body = <String, Object?>{'ok': true};
    if (data != null) body.addAll(data);
    return Response.ok(jsonEncode(body), headers: _jsonHeaders);
  }

  static Response created([Map<String, Object?>? data]) {
    final body = <String, Object?>{'ok': true};
    if (data != null) body.addAll(data);
    return Response(201, body: jsonEncode(body), headers: _jsonHeaders);
  }

  static Response error(int statusCode, String code, String message) {
    final body = {
      'ok': false,
      'error': {'code': code, 'message': message},
    };
    return Response(statusCode, body: jsonEncode(body), headers: _jsonHeaders);
  }

  static Response validation(String message) =>
      error(400, 'VALIDATION_ERROR', message);

  static Response unauthorized([String message = 'Unauthorized.']) =>
      error(401, 'UNAUTHORIZED', message);

  static Response forbidden([String message = 'Forbidden.']) =>
      error(403, 'FORBIDDEN', message);

  static Response notFound([String message = 'Not found.']) =>
      error(404, 'NOT_FOUND', message);

  static Response conflict([String message = 'Conflict.']) =>
      error(409, 'CONFLICT', message);

  static Response rateLimited([String message = 'Too many attempts.']) =>
      error(429, 'RATE_LIMITED', message);

  static Response storageError([String message = 'Storage unavailable.']) =>
      error(507, 'STORAGE_ERROR', message);

  static Response internal([String message = 'Internal server error.']) =>
      error(500, 'INTERNAL', message);
}

/// Wraps a handler and converts [AppException]s into proper HTTP responses.
Middleware errorHandler() {
  return (innerHandler) {
    return (Request request) async {
      try {
        return await innerHandler(request);
      } on ValidationException catch (e) {
        return ApiResponses.validation(e.message);
      } on NotFoundException catch (e) {
        return ApiResponses.notFound(e.message);
      } on ConflictException catch (e) {
        return ApiResponses.conflict(e.message);
      } on AuthException catch (e) {
        return ApiResponses.unauthorized(e.message);
      } on StorageException catch (e) {
        return ApiResponses.storageError(e.message);
      } on FormatException {
        return ApiResponses.validation('Malformed request body.');
      } catch (e, st) {
        logError('Unhandled API error', e, st);
        return ApiResponses.internal();
      }
    };
  };
}