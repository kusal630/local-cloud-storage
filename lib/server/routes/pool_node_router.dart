import 'dart:convert';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../middleware/api_responses.dart';
import '../pool/pool_node.dart';

/// Constant-time check of the coordinator's capability token.
///
/// The presented token is hashed with SHA-256 (lowercase hex, always 64
/// chars) and compared against the configured [tokenHash] byte-wise without
/// an early exit — a wrong token is rejected with the same work as a right
/// one (CONSULT §6 control 2: tokens are stored hashed, blast radius is one
/// node).
bool _tokenMatches(String presented, String tokenHash) {
  final digest = utf8.encode(Cipher.sha256String(presented));
  final expected = utf8.encode(tokenHash);
  return Cipher.constantTimeEquals(digest, expected);
}

/// Maps a [PoolNodeOutcome] onto the shared JSON error envelope.
Response _errorFor(PoolNodeOutcome outcome, String message) =>
    switch (outcome) {
      PoolNodeOutcome.success =>
        ApiResponses.internal('Unexpected success outcome.'),
      PoolNodeOutcome.noSpace =>
        ApiResponses.error(409, 'NO_SPACE', message),
      PoolNodeOutcome.noHold =>
        ApiResponses.error(409, 'NO_HOLD', message),
      PoolNodeOutcome.hashMismatch =>
        ApiResponses.error(400, 'HASH_MISMATCH', message),
      PoolNodeOutcome.invalidId =>
        ApiResponses.validation('Invalid chunk id.'),
      PoolNodeOutcome.invalidRequest => ApiResponses.validation(message),
      PoolNodeOutcome.conflict =>
        ApiResponses.error(409, 'CONFLICT', message),
      PoolNodeOutcome.notFound => ApiResponses.notFound(message),
    };

/// Route handlers for the contributor-node API (v2.4.0 Pooled Data Cloud).
///
/// Thin JSON/HTTP adapter over [PoolNodeStore]; every route lives under
/// `/node/v1` and speaks the standard envelope
/// `{"ok":true,…}` / `{"ok":false,"error":{"code","message"}}`.
class _NodeHandlers {
  _NodeHandlers(this.store);

  final PoolNodeStore store;

  Future<Map<String, Object?>> _jsonBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const ValidationException('JSON body must be an object.');
    }
    return decoded;
  }

  /// `idempotency_key` (non-empty string), `chunk_id` (string) and a
  /// non-negative `bytes` size — everything else is a 400.
  ({String idempotencyKey, String chunkId, int bytes}) _reservation(
    Map<String, Object?> body,
  ) {
    final key = body['idempotency_key'];
    final chunkId = body['chunk_id'];
    final bytes = body['bytes'];
    if (key is! String || key.isEmpty) {
      throw const ValidationException('idempotency_key must be a string.');
    }
    if (chunkId is! String) {
      throw const ValidationException('chunk_id must be a string.');
    }
    if (bytes is! int || bytes < 0) {
      throw const ValidationException(
        'bytes must be a non-negative integer.',
      );
    }
    return (idempotencyKey: key, chunkId: chunkId, bytes: bytes);
  }

  String _reservationKey(Map<String, Object?> body) {
    final key = body['idempotency_key'];
    if (key is! String || key.isEmpty) {
      throw const ValidationException('idempotency_key must be a string.');
    }
    return key;
  }

  String _chunkIdField(Map<String, Object?> body) {
    final chunkId = body['chunk_id'];
    if (chunkId is! String) {
      throw const ValidationException('chunk_id must be a string.');
    }
    return chunkId;
  }

  /// 400 for anything that is not a canonical chunk id — the id never
  /// reaches the store, and therefore never reaches a path
  /// (CONSULT §6 control 5).
  Response? _rejectBadId(String chunkId) {
    if (PoolNodeStore.isValidChunkId(chunkId)) return null;
    return ApiResponses.validation('Invalid chunk id.');
  }

  // ---------------------------------------------------------------------------
  // Routes
  // ---------------------------------------------------------------------------

  /// `GET /node/v1/status` — capacity of this node.
  Future<Response> status(Request request) async => ApiResponses.ok({
        'used_bytes': store.usedBytes,
        'quota_bytes': store.quotaBytes,
        'held_bytes': store.heldBytes,
        'chunk_count': store.chunkCount,
        'disk_free_bytes': await store.diskFreeBytes(),
      });

  /// `POST /node/v1/hold` — reserve quota for one chunk (CONSULT §2 step 1).
  Future<Response> hold(Request request) async {
    final body = await _jsonBody(request);
    final reservation = _reservation(body);
    final result = await store.hold(
      idempotencyKey: reservation.idempotencyKey,
      chunkId: reservation.chunkId,
      bytes: reservation.bytes,
    );
    if (!result.isSuccess) {
      return _errorFor(result.outcome, 'Reservation refused.');
    }
    return ApiResponses.ok({'bytes': result.bytes});
  }

  /// `PUT /node/v1/chunk/<chunkId>` — stage raw bytes under a hold.
  ///
  /// Requires `X-Idempotency-Key`; `X-Chunk-Sha256` (lowercase hex) is
  /// verified when present.
  Future<Response> putChunk(Request request, String chunkId) async {
    final badId = _rejectBadId(chunkId);
    if (badId != null) return badId;
    final idempotencyKey = request.headers['x-idempotency-key'];
    if (idempotencyKey == null || idempotencyKey.isEmpty) {
      throw const ValidationException(
        'X-Idempotency-Key header is required.',
      );
    }
    final expectedSha256 = request.headers['x-chunk-sha256'];
    final bytes = await request.read().expand((part) => part).toList();
    final result = await store.put(
      idempotencyKey: idempotencyKey,
      chunkId: chunkId,
      bytes: bytes,
      expectedSha256: expectedSha256,
    );
    if (!result.isSuccess) {
      return _errorFor(result.outcome, 'Chunk write refused.');
    }
    return ApiResponses.ok({'sha256': result.sha256, 'bytes': result.bytes});
  }

  /// `GET /node/v1/chunk/<chunkId>` — raw committed bytes.
  Future<Response> getChunk(Request request, String chunkId) async {
    final badId = _rejectBadId(chunkId);
    if (badId != null) return badId;
    final bytes = await store.read(chunkId);
    if (bytes == null) return ApiResponses.notFound('Chunk not found.');
    return Response.ok(
      bytes,
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': '${bytes.length}',
        'x-chunk-sha256': Cipher.sha256Hex(bytes),
      },
    );
  }

  /// `DELETE /node/v1/chunk/<chunkId>` — drop a replica (404 when absent).
  Future<Response> deleteChunk(Request request, String chunkId) async {
    final badId = _rejectBadId(chunkId);
    if (badId != null) return badId;
    final removed = await store.delete(chunkId);
    if (!removed) return ApiResponses.notFound('Chunk not found.');
    return ApiResponses.ok();
  }

  /// `POST /node/v1/commit` — verify the digest and promote the staged
  /// bytes into `chunks/` (CONSULT §2 step 2). Idempotent.
  Future<Response> commit(Request request) async {
    final body = await _jsonBody(request);
    final idempotencyKey = _reservationKey(body);
    final chunkId = _chunkIdField(body);
    final badId = _rejectBadId(chunkId);
    if (badId != null) return badId;
    final sha256 = body['sha256'];
    if (sha256 is! String) {
      throw const ValidationException('sha256 must be a string.');
    }
    final result = await store.commit(
      idempotencyKey: idempotencyKey,
      chunkId: chunkId,
      sha256: sha256,
    );
    if (!result.isSuccess) {
      return _errorFor(result.outcome, 'Commit refused.');
    }
    return ApiResponses.ok({'sha256': result.sha256, 'bytes': result.bytes});
  }

  /// `POST /node/v1/abort` — release a reservation; always `{"ok":true}`.
  Future<Response> abort(Request request) async {
    final body = await _jsonBody(request);
    await store.abort(_reservationKey(body));
    return ApiResponses.ok();
  }

  /// `POST /node/v1/wipe` — erase every chunk; requires
  /// `{"confirm":"wipe"}` (403 otherwise).
  Future<Response> wipe(Request request) async {
    final body = await _jsonBody(request);
    if (body['confirm'] != 'wipe') {
      return ApiResponses.forbidden(
        'Send {"confirm":"wipe"} to erase every chunk on this node.',
      );
    }
    final deleted = await store.wipe();
    return ApiResponses.ok({'deleted': deleted});
  }
}

/// Rejects any request without a valid `X-Pool-Token` (401) before it can
/// reach a route; runs outside [errorHandler] so even malformed bodies are
/// only visible to an authenticated coordinator.
Middleware _requireToken(String tokenHash) {
  return (Handler innerHandler) {
    return (Request request) async {
      final presented = request.headers['x-pool-token'];
      if (presented == null || presented.isEmpty) {
        return ApiResponses.unauthorized();
      }
      if (!_tokenMatches(presented, tokenHash)) {
        logWarn('Pool node rejected an invalid X-Pool-Token.');
        return ApiResponses.unauthorized();
      }
      return innerHandler(request);
    };
  };
}

/// Builds the HTTP surface of a contributor node.
///
/// Routes (all under `/node/v1`, all guarded by `X-Pool-Token`):
///
/// | Method | Path | Success body |
/// |--------|------|--------------|
/// | GET    | `/node/v1/status` | `{ok, used_bytes, quota_bytes, held_bytes, chunk_count, disk_free_bytes}` |
/// | POST   | `/node/v1/hold` | `{ok, bytes}` |
/// | PUT    | `/node/v1/chunk/<chunkId>` | `{ok, sha256, bytes}` |
/// | GET    | `/node/v1/chunk/<chunkId>` | raw bytes + `content-length`, `x-chunk-sha256` |
/// | DELETE | `/node/v1/chunk/<chunkId>` | `{ok}` |
/// | POST   | `/node/v1/commit` | `{ok, sha256, bytes}` |
/// | POST   | `/node/v1/abort` | `{ok}` |
/// | POST   | `/node/v1/wipe` | `{ok, deleted}` |
///
/// Errors use the shared envelope: 401 `UNAUTHORIZED` (missing/wrong
/// token), 400 for malformed bodies/ids (`HASH_MISMATCH` for a bad
/// digest), 409 `NO_SPACE` / `NO_HOLD` / `CONFLICT`, 404 for a missing
/// chunk, 403 for an unconfirmed wipe (spec: `RESEARCH/CONSULT.md` §2
/// reservations, §6 controls 2, 5 & 8).
///
/// [tokenHash] is the lowercase hex SHA-256 of the capability token the
/// coordinator must present.
Handler buildPoolNodeHandler({
  required PoolNodeStore store,
  required String tokenHash,
}) {
  final handlers = _NodeHandlers(store);

  final router = Router()
    ..get('/node/v1/status', handlers.status)
    ..post('/node/v1/hold', handlers.hold)
    ..put('/node/v1/chunk/<chunkId>', handlers.putChunk)
    ..get('/node/v1/chunk/<chunkId>', handlers.getChunk)
    ..delete('/node/v1/chunk/<chunkId>', handlers.deleteChunk)
    ..post('/node/v1/commit', handlers.commit)
    ..post('/node/v1/abort', handlers.abort)
    ..post('/node/v1/wipe', handlers.wipe);

  return const Pipeline()
      .addMiddleware(errorHandler())
      .addMiddleware(_requireToken(tokenHash))
      .addHandler(router.call);
}
