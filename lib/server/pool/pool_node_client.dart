import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';


/// One call to a contributor storage node, normalized across HTTP status
/// codes and transport failures so the coordinator can branch on
/// [errorCode] instead of catching exceptions.
class NodeCall {
  const NodeCall({
    required this.ok,
    required this.statusCode,
    this.errorCode,
    this.message,
    this.body = const {},
    this.bytes,
  });

  final bool ok;
  final int statusCode;

  /// `NO_SPACE`, `UNAUTHORIZED`, `NOT_FOUND`, `TIMEOUT`, `UNREACHABLE`, …
  final String? errorCode;
  final String? message;
  final Map<String, Object?> body;
  final List<int>? bytes;

  /// The contributor refused the write because of its own cap or disk —
  /// a normal outcome that makes the planner re-place elsewhere (§5.4).
  bool get isNoSpace => errorCode == 'NO_SPACE';
  bool get isUnauthorized => statusCode == 401 || errorCode == 'UNAUTHORIZED';
  bool get isMissing => statusCode == 404 || errorCode == 'NOT_FOUND';
  bool get isTransportFailure =>
      errorCode == 'TIMEOUT' || errorCode == 'UNREACHABLE';

  static const NodeCall unavailable = NodeCall(
    ok: false,
    statusCode: 0,
    errorCode: 'UNREACHABLE',
    message: 'Contributor unreachable.',
  );
}

/// Credentials + TLS pin for one contributor node.
class NodeTarget {
  const NodeTarget({
    required this.baseUrl,
    required this.token,
    this.fingerprint,
  });

  /// `https://192.168.1.5:5321` (no trailing slash).
  final String baseUrl;

  /// Contributor capability token — presented as `X-Pool-Token`.
  final String token;

  /// Pinned SHA-256 fingerprint of the node certificate (lowercase hex).
  /// When set, TLS succeeds only if the presented chain matches: LAN MITM
  /// protection for self-signed node certs.
  final String? fingerprint;

  Uri uri(String path, [Map<String, String>? query]) => Uri.parse(
        '$baseUrl$path${query == null || query.isEmpty ? '' : '?${query.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&')}'}',
      );
}

/// HTTP client for contributor storage nodes.
///
/// Transport rules (CONSULT §1 + §6):
/// * every request carries the contributor capability token;
/// * TLS is pinned to the certificate fingerprint recorded at registration;
/// * chunk payloads are already AES-256-GCM ciphertext at this layer, so a
///   failed pin can never leak plaintext — it fails closed.
class PoolNodeClient {
  PoolNodeClient({Duration? timeout}) : _timeout = timeout ?? _defaultTimeout;

  static const Duration _defaultTimeout = Duration(seconds: 20);

  final Duration _timeout;
  final Map<String, HttpClient> _clients = {};

  HttpClient _clientFor(NodeTarget target) {
    final key = '${target.baseUrl}|${target.fingerprint ?? ''}';
    final existing = _clients[key];
    if (existing != null) return existing;
    // The fingerprint must be the ONLY thing that can accept a certificate.
    //
    // Dart consults `badCertificateCallback` only *after* chain validation has
    // failed, so with the system trust store attached, any publicly-trusted
    // certificate for the right hostname validates on its own and the callback
    // — the one place we compare the pin — never runs. Dropping the trust
    // store means every handshake comes to us for a decision, so the pin is
    // checked on every connection instead of only on the weak ones. Nothing
    // here can be trusted by the OS on the peer's behalf (CONSULT §5: all pool
    // traffic rides a *pinned* channel, not merely a valid one).
    //
    // The context is a constructor argument: `HttpClient.context` is final
    // (read-only) since Dart 3, so a trust store can only be chosen at
    // construction.
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 5);
    final pinned = target.fingerprint?.toLowerCase().replaceAll(':', '');
    client.badCertificateCallback = (cert, host, port) {
      if (pinned == null || pinned.isEmpty) return false;
      try {
        return sha256.convert(cert.der).toString() == pinned;
      } catch (_) {
        return false;
      }
    };
    _clients[key] = client;
    return client;
  }

  /// Closes every cached connection pool.
  void close() {
    for (final client in _clients.values) {
      client.close(force: true);
    }
    _clients.clear();
  }

  Future<NodeCall> _request(
    NodeTarget target,
    String method,
    String path, {
    Object? json,
    List<int>? raw,
    Map<String, String> headers = const {},
    bool expectBytes = false,
  }) async {
    final Uri url;
    try {
      url = target.uri(path);
    } catch (e) {
      return NodeCall(
        ok: false,
        statusCode: 0,
        errorCode: 'UNREACHABLE',
        message: 'Bad endpoint: $e',
      );
    }
    try {
      final client = _clientFor(target);
      final request = await client
          .openUrl(method, url)
          .timeout(const Duration(seconds: 5));
      request.headers.set('X-Pool-Token', target.token);
      request.headers.contentType = ContentType.json;
      headers.forEach((k, v) => request.headers.set(k, v));
      final body = raw ??
          (json == null ? null : utf8.encode(jsonEncode(json)));
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final response = await request.close().timeout(_timeout);
      final collected = await response.fold<BytesBuilder>(
        BytesBuilder(),
        (acc, chunk) => acc..add(chunk),
      ).timeout(_timeout);
      final data = collected.takeBytes();
      if (expectBytes && response.statusCode == 200) {
        return NodeCall(
          ok: true,
          statusCode: 200,
          bytes: data,
          body: _headersAsMap(response.headers),
        );
      }
      Map<String, Object?> decoded = const {};
      if (data.isNotEmpty) {
        try {
          final value = jsonDecode(utf8.decode(data, allowMalformed: true));
          if (value is Map<String, dynamic>) decoded = value;
        } catch (_) {}
      }
      final ok = response.statusCode >= 200 && response.statusCode < 300;
      String? errorCode;
      String? message;
      if (!ok) {
        final error = decoded['error'];
        if (error is Map) {
          errorCode = error['code']?.toString();
          message = error['message']?.toString();
        }
        errorCode ??= _defaultErrorCode(response.statusCode);
        message ??= 'Contributor returned ${response.statusCode}.';
      }
      return NodeCall(
        ok: ok,
        statusCode: response.statusCode,
        errorCode: errorCode,
        message: message,
        body: decoded,
      );
    } on TimeoutException {
      return const NodeCall(
        ok: false,
        statusCode: 0,
        errorCode: 'TIMEOUT',
        message: 'Contributor did not respond in time.',
      );
    } on SocketException catch (e) {
      return NodeCall(
        ok: false,
        statusCode: 0,
        errorCode: 'UNREACHABLE',
        message: 'Contributor unreachable: ${e.message}',
      );
    } on HandshakeException {
      final pinned = (target.fingerprint ?? '').trim();
      // Two very different failures share this exception, and "identity not
      // verifiable" is not the same problem as "identity proved wrong" — the
      // fix for one is registering the device properly, for the other
      // investigating a spoof.
      if (pinned.isEmpty) {
        return const NodeCall(
          ok: false,
          statusCode: 0,
          errorCode: 'NO_FINGERPRINT',
          message: 'Contributor has no pinned certificate fingerprint, so its '
              'identity cannot be verified. Re-register it with the 64-hex '
              'SHA-256 of its node certificate.',
        );
      }
      return const NodeCall(
        ok: false,
        statusCode: 0,
        errorCode: 'PIN_MISMATCH',
        message: 'Contributor certificate does not match its pinned fingerprint.',
      );
    } catch (e) {
      return NodeCall(
        ok: false,
        statusCode: 0,
        errorCode: 'UNREACHABLE',
        message: 'Contributor call failed: $e',
      );
    }
  }

  static String _defaultErrorCode(int status) {
    switch (status) {
      case 401:
        return 'UNAUTHORIZED';
      case 403:
        return 'FORBIDDEN';
      case 404:
        return 'NOT_FOUND';
      case 409:
        return 'CONFLICT';
      case 429:
        return 'RATE_LIMITED';
      default:
        return status >= 500 ? 'NODE_ERROR' : 'REQUEST_REJECTED';
    }
  }

  static Map<String, Object?> _headersAsMap(HttpHeaders headers) => {
        for (final name in ['x-chunk-sha256', 'content-length'])
          if (headers.value(name) != null) name: headers.value(name)!,
      };

  // --- Protocol (mirrors `buildPoolNodeHandler`) -------------------------

  Future<NodeCall> status(NodeTarget target) =>
      _request(target, 'GET', '/node/v1/status');

  Future<NodeCall> hold(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required int bytes,
  }) =>
      _request(target, 'POST', '/node/v1/hold', json: {
        'idempotency_key': idempotencyKey,
        'chunk_id': chunkId,
        'bytes': bytes,
      });

  Future<NodeCall> put(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required List<int> payload,
    String? sha256Hex,
  }) =>
      _request(
        target,
        'PUT',
        '/node/v1/chunk/$chunkId',
        raw: payload,
        headers: {
          'X-Idempotency-Key': idempotencyKey,
          if (sha256Hex != null) 'X-Chunk-Sha256': sha256Hex,
          'content-type': 'application/octet-stream',
        },
      );

  Future<NodeCall> get(NodeTarget target, String chunkId) =>
      _request(target, 'GET', '/node/v1/chunk/$chunkId', expectBytes: true);

  Future<NodeCall> delete(NodeTarget target, String chunkId) =>
      _request(target, 'DELETE', '/node/v1/chunk/$chunkId');

  Future<NodeCall> commit(
    NodeTarget target, {
    required String idempotencyKey,
    required String chunkId,
    required String sha256,
  }) =>
      _request(target, 'POST', '/node/v1/commit', json: {
        'idempotency_key': idempotencyKey,
        'chunk_id': chunkId,
        'sha256': sha256,
      });

  Future<NodeCall> abort(NodeTarget target, {required String idempotencyKey}) =>
      _request(target, 'POST', '/node/v1/abort',
          json: {'idempotency_key': idempotencyKey});

  Future<NodeCall> wipe(NodeTarget target) => _request(
      target, 'POST', '/node/v1/wipe', json: {'confirm': 'wipe'});

  /// Logs a failed call once so the audit trail has a reason string.
  static String describe(NodeCall call) =>
      '${call.errorCode ?? 'HTTP ${call.statusCode}'}'
      '${call.message == null ? '' : ': ${call.message}'}';
}
