import 'dart:convert';
import 'dart:io';

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

  /// File download with single-range support (shared by REST + WebDAV).
  static Response rangedFile(
    File file,
    int length,
    String? mimeType,
    String name,
    String? rangeHeader, {
    bool attachment = true,
  }) {
    final headers = <String, Object>{
      'accept-ranges': 'bytes',
      'content-type': mimeType ?? 'application/octet-stream',
    };
    if (attachment) {
      headers['content-disposition'] =
          'attachment; filename="${_escape(name)}"';
    }
    if (rangeHeader == null || rangeHeader.isEmpty) {
      headers['content-length'] = '$length';
      return Response(200, body: file.openRead(), headers: headers);
    }
    final match =
        RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
    if (match == null) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }
    int? start =
        match.group(1)!.isEmpty ? null : int.tryParse(match.group(1)!);
    int? end = match.group(2)!.isEmpty ? null : int.tryParse(match.group(2)!);
    if (start == null && end == null) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }
    if (start == null) {
      final suffix = end!;
      if (suffix <= 0) {
        headers['content-range'] = 'bytes */$length';
        return Response(416, headers: headers, body: '');
      }
      start = (length - suffix).clamp(0, length);
      end = length - 1;
    }
    if (end == null || end >= length) {
      end = length - 1;
    }
    if (start > end || start >= length) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }
    headers['content-range'] = 'bytes $start-$end/$length';
    headers['content-length'] = '${end - start + 1}';
    return Response(206,
        body: file.openRead(start, end + 1), headers: headers);
  }

  static String _escape(String value) => value
      .replaceAll('"', r'\"')
      .replaceAll('\n', '')
      .replaceAll('\r', '');
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
      } on QuotaException catch (e) {
        return ApiResponses.error(409, 'QUOTA_EXCEEDED', e.message);
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