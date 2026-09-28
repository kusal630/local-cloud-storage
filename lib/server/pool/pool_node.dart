import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/disk_space_compat.dart';

/// Best-effort owner-only (`0700`) permissions for a node directory —
/// mirrors `_chmodOwnerOnly` in `lib/core/utils/pool_cipher.dart` (POSIX
/// only; Windows ACLs are out of scope for this slice).
Future<void> _chmodOwnerOnly(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isAndroid) return;
  try {
    await Process.run('chmod', ['700', path]);
  } catch (_) {
    // Best effort — same policy as the vault directory lockdown.
  }
}

/// Outcome shared by [HoldResult], [PutResult] and [CommitResult].
///
/// The HTTP adapter (`lib/server/routes/pool_node_router.dart`) maps these
/// onto the JSON error envelope (spec: `RESEARCH/CONSULT.md` §2 and §6).
enum PoolNodeOutcome {
  /// The operation was accepted.
  success,

  /// The node's own quota cap or the free-disk watermark would be exceeded
  /// (HTTP 409 `NO_SPACE`).
  noSpace,

  /// No live hold matches both the idempotency key and the chunk id
  /// (HTTP 409 `NO_HOLD`).
  noHold,

  /// SHA-256 of the staged bytes does not equal the expected digest
  /// (HTTP 400 `HASH_MISMATCH`); the bytes are never promoted.
  hashMismatch,

  /// Chunk id does not match `^[0-9a-f]{64}$` — rejected before any path
  /// is built (CONSULT §6 control 5, HTTP 400).
  invalidId,

  /// The idempotency key is already bound to a *different* chunk id or
  /// reservation size (HTTP 409 `CONFLICT`).
  conflict,

  /// Nothing to act on: no staged bytes for the commit, or the chunk does
  /// not exist (HTTP 404).
  notFound,

  /// Malformed arguments (negative size, empty idempotency key) — HTTP 400.
  invalidRequest,
}

/// Result of [PoolNodeStore.hold].
class HoldResult {
  const HoldResult(this.outcome, {this.bytes = 0});

  /// What happened; [PoolNodeOutcome.success] means the bytes are reserved.
  final PoolNodeOutcome outcome;

  /// Bytes reserved on success, `0` otherwise.
  final int bytes;

  bool get isSuccess => outcome == PoolNodeOutcome.success;

  @override
  String toString() => 'HoldResult(${outcome.name}, bytes: $bytes)';
}

/// Result of [PoolNodeStore.put].
class PutResult {
  const PutResult(this.outcome, {this.sha256, this.bytes = 0});

  final PoolNodeOutcome outcome;

  /// Lowercase hex SHA-256 of the staged bytes on success.
  final String? sha256;

  /// Bytes written to `tmp/` on success, `0` otherwise.
  final int bytes;

  bool get isSuccess => outcome == PoolNodeOutcome.success;

  @override
  String toString() => 'PutResult(${outcome.name}, bytes: $bytes, sha256: $sha256)';
}

/// Result of [PoolNodeStore.commit].
class CommitResult {
  const CommitResult(this.outcome, {this.sha256, this.bytes = 0});

  final PoolNodeOutcome outcome;

  /// Lowercase hex SHA-256 verified against the bytes on disk on success.
  final String? sha256;

  /// Bytes now counted in [PoolNodeStore.usedBytes] on success.
  final int bytes;

  bool get isSuccess => outcome == PoolNodeOutcome.success;

  @override
  String toString() => 'CommitResult(${outcome.name}, bytes: $bytes, sha256: $sha256)';
}

/// One reservation, in-memory form of the CONSULT §2 `reservations` row:
/// `idempotency_key` is the map key, [expiresAt] is the TTL deadline and
/// [partPath] is the `tmp/` staging file the reservation owns.
class _Hold {
  _Hold({
    required this.chunkId,
    required this.bytes,
    required this.expiresAt,
    required this.partPath,
  });

  final String chunkId;
  final int bytes;
  final DateTime expiresAt;

  /// `<dir>/tmp/<16-hex>.part` — never derived from client input.
  final String partPath;

  /// SHA-256 recorded by the last successful [PoolNodeStore.put].
  String? sha256;
}

/// Pure storage engine behind one contributor node of the v2.4.0 Pooled
/// Data Cloud — spec: `RESEARCH/CONSULT.md` §2 (optimistic reservation
/// with idempotency key + TTL), §5.4 (the contributor is authoritative for
/// its own cap) and §6 controls 3 & 5 (quota enforced on write, chunk ids
/// canonicalised before they ever touch a path).
///
/// Deliberately free of HTTP and Flutter concerns: the shelf adapter in
/// `lib/server/routes/pool_node_router.dart` is thin, and unit tests drive
/// this class directly.
///
/// On-disk layout:
///
/// ```text
/// <dir>/chunks/<id[0..2]>/<id[2..4]>/<id>   committed chunks
/// <dir>/tmp/<16-hex>.part                    staging, promoted by rename
/// ```
///
/// Lifecycle: `hold` reserves quota → `put` stages bytes in `tmp/` →
/// `commit` verifies the digest and atomically renames into `chunks/`
/// (only then does [usedBytes] grow) → `abort`/TTL expiry releases the
/// reservation without keeping bytes.
class PoolNodeStore {
  PoolNodeStore({
    required this._dir,
    required this._quotaBytes,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    if (_quotaBytes < 0) {
      throw const ValidationException('quotaBytes must be >= 0');
    }
  }

  /// Reservation TTL: a crashed writer can pin quota for at most 10 minutes
  /// (CONSULT §2 protocol step 4).
  static const Duration holdTtl = Duration(seconds: 600);

  /// Free space that must remain on the node's filesystem after accepting a
  /// write, so a contributor never fills its own disk (CONSULT §5.4).
  static const int diskWatermarkBytes = 64 * 1024 * 1024;

  /// The only shape a chunk id may have before it is joined into a path
  /// (CONSULT §6 control 5 — path traversal).
  static final RegExp chunkIdPattern = RegExp(r'^[0-9a-f]{64}$');

  /// Whether [chunkId] is a canonical lowercase 64-hex SHA-256 id.
  static bool isValidChunkId(String chunkId) => chunkIdPattern.hasMatch(chunkId);

  final Directory _dir;
  final DateTime Function() _clock;

  int _quotaBytes;
  int _usedBytes = 0;
  int _chunkCount = 0;

  /// Live reservations by idempotency key; expired entries are dropped by
  /// [sweep] (or lazily by the next mutating call).
  final Map<String, _Hold> _holds = {};

  /// Serializes every mutating operation so the oversubscription check of
  /// CONSULT §2 is atomic: two holds racing for the last free byte queue up
  /// instead of both winning.
  Future<void> _chain = Future<void>.value();

  // ---------------------------------------------------------------------------
  // Paths — built only from ids that already passed [isValidChunkId].
  // ---------------------------------------------------------------------------

  Directory get _chunksDir => Directory(p.join(_dir.path, 'chunks'));

  Directory get _tmpDir => Directory(p.join(_dir.path, 'tmp'));

  /// `<dir>/chunks/<id[0..2]>/<id[2..4]>/<id>`.
  String _chunkPath(String chunkId) => p.join(
        _dir.path,
        'chunks',
        chunkId.substring(0, 2),
        chunkId.substring(2, 4),
        chunkId,
      );

  // ---------------------------------------------------------------------------
  // Accounting
  // ---------------------------------------------------------------------------

  /// The node's own cap in bytes (CONSULT §5.4: authoritative here, never
  /// taken from the coordinator). Changeable via [setQuota].
  int get quotaBytes => _quotaBytes;

  /// Committed bytes on disk — maintained incrementally, reconciled by
  /// [open].
  int get usedBytes => _usedBytes;

  /// Sum of the *live* holds (expired reservations no longer count against
  /// the cap; they disappear for good on [sweep]).
  int get heldBytes => _holds.values
      .where((hold) => !_isExpired(hold))
      .fold(0, (sum, hold) => sum + hold.bytes);

  /// Number of committed chunks.
  int get chunkCount => _chunkCount;

  /// Raises or lowers this node's cap at runtime.
  void setQuota(int quotaBytes) {
    if (quotaBytes < 0) {
      throw const ValidationException('quotaBytes must be >= 0');
    }
    _quotaBytes = quotaBytes;
  }

  bool _isExpired(_Hold hold) => _clock().isAfter(hold.expiresAt);

  /// Live hold for [idempotencyKey] bound to [chunkId], else `null`.
  _Hold? _liveHold(String idempotencyKey, String chunkId) {
    final hold = _holds[idempotencyKey];
    if (hold == null || _isExpired(hold) || hold.chunkId != chunkId) return null;
    return hold;
  }

  /// Digest equality that rejects anything but a canonical lowercase
  /// 64-hex SHA-256 and compares the rest in constant time (mirrors
  /// `PoolCipher.verifyPlaintextSha256`).
  static bool _shaEquals(String actualHex, String expectedHex) {
    if (expectedHex.length != 64 || !chunkIdPattern.hasMatch(expectedHex)) {
      return false;
    }
    return Cipher.constantTimeEquals(
      utf8.encode(actualHex),
      utf8.encode(expectedHex),
    );
  }

  // ---------------------------------------------------------------------------
  // Admission control (CONSULT §2 — evaluated inside the store, never
  // delegated to the caller)
  // ---------------------------------------------------------------------------

  /// Returns `null` when an incoming write of [bytes] fits, otherwise
  /// [PoolNodeOutcome.noSpace].
  ///
  /// Two conditions must both hold:
  ///
  /// * `usedBytes + heldBytes + bytes <= quotaBytes` (the oversubscription
  ///   invariant of CONSULT §2), and
  /// * `diskFreeBytes() - bytes >= 64 MiB` so the node keeps its watermark
  ///   (CONSULT §5.4 — a contributor never fills its own filesystem).
  ///
  /// [heldOverride] replaces [heldBytes] for callers that already own part
  /// of the reservation (`put`/`commit` re-checking their own hold, so the
  /// held bytes are not double-counted). Unknown free space (`df`
  /// unavailable) is never treated as zero — only the cap applies, per the
  /// `DiskSpaceCompat` contract.
  Future<PoolNodeOutcome?> _admit(int bytes, {int? heldOverride}) async {
    final held = heldOverride ?? heldBytes;
    if (_usedBytes + held + bytes > _quotaBytes) {
      return PoolNodeOutcome.noSpace;
    }
    final free = await _freeBytesOrNull();
    if (free != null && free - bytes < diskWatermarkBytes) {
      return PoolNodeOutcome.noSpace;
    }
    return null;
  }

  Future<int?> _freeBytesOrNull() async =>
      (await DiskSpaceCompat.getSpace(_dir.path))?.free;

  /// Real free space of the filesystem backing the node directory; `0` when
  /// the platform cannot report it (unknown, see [_admit]).
  Future<int> diskFreeBytes() async => (await _freeBytesOrNull()) ?? 0;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Prepares the node directory: creates `<dir>`, `<dir>/chunks` and
  /// `<dir>/tmp` (owner-only `0700`, best effort), recomputes [usedBytes]
  /// and [chunkCount] from what is actually on disk, and sweeps leftover
  /// staging files in `tmp/`.
  ///
  /// Must be awaited before the first operation; safe to call again.
  Future<void> open() {
    return _synchronized(() async {
      await _dir.create(recursive: true);
      await _chmodOwnerOnly(_dir.path);
      await _chunksDir.create(recursive: true);
      await _chmodOwnerOnly(_chunksDir.path);
      await _tmpDir.create(recursive: true);
      await _chmodOwnerOnly(_tmpDir.path);

      var used = 0;
      var count = 0;
      if (await _chunksDir.exists()) {
        await for (final entity
            in _chunksDir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          used += await entity.length();
          count++;
        }
      }
      _usedBytes = used;
      _chunkCount = count;
      _holds.clear();
      // No hold survives a restart, so every staging file is an orphan.
      sweep();
      logInfo(
        'Pool node ready at ${_dir.path} '
        '($count chunk(s), $used committed byte(s)).',
      );
    });
  }

  /// Drops expired holds (releasing their [heldBytes] and staging file) and
  /// removes stale `tmp/` files no live hold owns. Synchronous by design —
  /// call it from a timer.
  void sweep() {
    _holds.removeWhere((_, hold) {
      if (!_isExpired(hold)) return false;
      _deleteFileSync(hold.partPath);
      return true;
    });
    final referenced = _holds.values.map((hold) => hold.partPath).toList();
    _removeStaleTmpSync(referenced);
  }

  // ---------------------------------------------------------------------------
  // Reservations (CONSULT §2)
  // ---------------------------------------------------------------------------

  /// Reserves [bytes] of quota for [chunkId] until [holdTtl] elapses.
  ///
  /// Idempotent: retrying the same key with the same chunk id and size
  /// returns the existing reservation. Reusing a *live* key with a
  /// different chunk id or size returns [PoolNodeOutcome.conflict].
  Future<HoldResult> hold({
    required String idempotencyKey,
    required String chunkId,
    required int bytes,
  }) async {
    if (!isValidChunkId(chunkId)) {
      return const HoldResult(PoolNodeOutcome.invalidId);
    }
    if (idempotencyKey.isEmpty || bytes < 0) {
      return const HoldResult(PoolNodeOutcome.invalidRequest);
    }
    return _synchronized(() async {
      final existing = _holds[idempotencyKey];
      if (existing != null && !_isExpired(existing)) {
        if (existing.chunkId == chunkId && existing.bytes == bytes) {
          return HoldResult(PoolNodeOutcome.success, bytes: existing.bytes);
        }
        return const HoldResult(PoolNodeOutcome.conflict);
      }
      if (existing != null) {
        // Expired leftover under the same key: release it, then re-reserve.
        _holds.remove(idempotencyKey);
        await _deleteFile(existing.partPath);
      }
      final denial = await _admit(bytes);
      if (denial != null) return HoldResult(denial);
      _holds[idempotencyKey] = _Hold(
        chunkId: chunkId,
        bytes: bytes,
        expiresAt: _clock().add(holdTtl),
        partPath: p.join(_tmpDir.path, '${Cipher.randomHex(16)}.part'),
      );
      return HoldResult(PoolNodeOutcome.success, bytes: bytes);
    });
  }

  /// Stages [bytes] in `tmp/` under a live hold for [idempotencyKey] +
  /// [chunkId]. Nothing is promoted to `chunks/` yet — that is [commit].
  ///
  /// [expectedSha256] (lowercase hex) is verified against the staged bytes
  /// before they touch the disk; a mismatch leaves the hold intact so the
  /// caller can retry with correct bytes.
  Future<PutResult> put({
    required String idempotencyKey,
    required String chunkId,
    required List<int> bytes,
    String? expectedSha256,
  }) async {
    if (!isValidChunkId(chunkId)) {
      return const PutResult(PoolNodeOutcome.invalidId);
    }
    if (idempotencyKey.isEmpty) {
      return const PutResult(PoolNodeOutcome.invalidRequest);
    }
    return _synchronized(() async {
      final hold = _liveHold(idempotencyKey, chunkId);
      if (hold == null) return const PutResult(PoolNodeOutcome.noHold);
      final denial = await _admit(
        bytes.length,
        heldOverride: heldBytes - hold.bytes,
      );
      if (denial != null) return PutResult(denial);
      final actual = Cipher.sha256Hex(bytes);
      if (expectedSha256 != null && !_shaEquals(actual, expectedSha256)) {
        return const PutResult(PoolNodeOutcome.hashMismatch);
      }
      final part = File(hold.partPath);
      await part.parent.create(recursive: true);
      await part.writeAsBytes(bytes, flush: true);
      hold.sha256 = actual;
      return PutResult(
        PoolNodeOutcome.success,
        sha256: actual,
        bytes: bytes.length,
      );
    });
  }

  /// Verifies the staged bytes against [sha256] and promotes them into
  /// `chunks/` with an atomic rename; only then does [usedBytes] grow and
  /// the hold expire (CONSULT §2 step 2).
  ///
  /// Idempotent: once the chunk is committed, repeating the same call
  /// verifies against the bytes already on disk and succeeds again without
  /// double-counting. A digest mismatch never promotes the partial file.
  Future<CommitResult> commit({
    required String idempotencyKey,
    required String chunkId,
    required String sha256,
  }) async {
    if (!isValidChunkId(chunkId)) {
      return const CommitResult(PoolNodeOutcome.invalidId);
    }
    if (idempotencyKey.isEmpty) {
      return const CommitResult(PoolNodeOutcome.invalidRequest);
    }
    return _synchronized(() async {
      final hold = _liveHold(idempotencyKey, chunkId);
      if (hold == null) {
        // Retry after success (or after a wipe/rollback): the chunk, if
        // any, is already committed — verify against what is on disk.
        return _commitFromDisk(chunkId, sha256);
      }
      final part = File(hold.partPath);
      if (!await part.exists()) {
        return const CommitResult(PoolNodeOutcome.notFound);
      }
      final staged = await part.readAsBytes();
      final actual = Cipher.sha256Hex(staged);
      if (!_shaEquals(actual, sha256)) {
        // Never promote mismatched bytes (CONSULT §6 control 1).
        return const CommitResult(PoolNodeOutcome.hashMismatch);
      }
      final denial = await _admit(
        staged.length,
        heldOverride: heldBytes - hold.bytes,
      );
      if (denial != null) return CommitResult(denial);

      final destination = File(_chunkPath(chunkId));
      await destination.parent.create(recursive: true);
      final alreadyThere = await destination.exists();
      final replacedBytes = alreadyThere ? await destination.length() : 0;
      await part.rename(destination.path);
      if (alreadyThere) {
        _usedBytes -= replacedBytes;
      } else {
        _chunkCount++;
      }
      _usedBytes += staged.length;
      if (_usedBytes < 0) _usedBytes = 0;
      _holds.remove(idempotencyKey);
      return CommitResult(
        PoolNodeOutcome.success,
        sha256: actual,
        bytes: staged.length,
      );
    });
  }

  /// Releases the reservation for [idempotencyKey] without keeping bytes.
  /// Idempotent — always `true`, even for an unknown key.
  Future<bool> abort(String idempotencyKey) {
    return _synchronized(() async {
      final hold = _holds.remove(idempotencyKey);
      if (hold != null) await _deleteFile(hold.partPath);
      return true;
    });
  }

  Future<CommitResult> _commitFromDisk(String chunkId, String sha256) async {
    final destination = File(_chunkPath(chunkId));
    if (!await destination.exists()) {
      return const CommitResult(PoolNodeOutcome.notFound);
    }
    final bytes = await destination.length();
    final actual = await Cipher.sha256File(destination);
    if (!_shaEquals(actual, sha256)) {
      return const CommitResult(PoolNodeOutcome.hashMismatch);
    }
    return CommitResult(PoolNodeOutcome.success, sha256: actual, bytes: bytes);
  }

  // ---------------------------------------------------------------------------
  // Chunks
  // ---------------------------------------------------------------------------

  /// Reads a committed chunk. Returns `null` when it is absent — and also
  /// when [chunkId] is malformed, in which case the id is never joined into
  /// a path (CONSULT §6 control 5).
  Future<List<int>?> read(String chunkId) async {
    if (!isValidChunkId(chunkId)) return null;
    final file = File(_chunkPath(chunkId));
    try {
      if (!await file.exists()) return null;
      return await file.readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// Deletes a committed chunk, returning `false` when it was absent (an
  /// invalid id is always "absent" and touches no path).
  Future<bool> delete(String chunkId) {
    return _synchronized(() async {
      if (!isValidChunkId(chunkId)) return false;
      final file = File(_chunkPath(chunkId));
      if (!await file.exists()) return false;
      final length = await file.length();
      await file.delete();
      _usedBytes -= length;
      if (_usedBytes < 0) _usedBytes = 0;
      _chunkCount--;
      if (_chunkCount < 0) _chunkCount = 0;
      return true;
    });
  }

  /// Erases every committed chunk plus all staging state (holds included),
  /// returning how many chunks were removed.
  Future<int> wipe() {
    return _synchronized(() async {
      var deleted = 0;
      if (await _chunksDir.exists()) {
        await for (final entity
            in _chunksDir.list(recursive: true, followLinks: false)) {
          if (entity is File) deleted++;
        }
        await _chunksDir.delete(recursive: true);
        await _chunksDir.create(recursive: true);
        await _chmodOwnerOnly(_chunksDir.path);
      }
      _holds.clear();
      if (await _tmpDir.exists()) {
        await for (final entity
            in _tmpDir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              await entity.delete();
            } catch (_) {
              // Best effort — a stray staging file must not abort a wipe.
            }
          }
        }
      }
      _usedBytes = 0;
      _chunkCount = 0;
      logInfo('Pool node wiped $deleted chunk(s) at ${_dir.path}.');
      return deleted;
    });
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Runs [body] with exclusive access to the store's accounting state.
  Future<T> _synchronized<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await body());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort — sweeper paths must never throw.
    }
  }

  void _deleteFileSync(String path) {
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best effort — sweeper paths must never throw.
    }
  }

  /// Removes every file in `tmp/` that no live hold owns.
  void _removeStaleTmpSync(List<String> referenced) {
    try {
      if (!_tmpDir.existsSync()) return;
      for (final entity in _tmpDir.listSync(followLinks: false)) {
        if (entity is! File) continue;
        if (referenced.any((path) => p.equals(path, entity.path))) continue;
        try {
          entity.deleteSync();
        } catch (_) {
          // Best effort.
        }
      }
    } catch (_) {
      // Best effort — a missing/unreadable tmp dir is not an error.
    }
  }
}
