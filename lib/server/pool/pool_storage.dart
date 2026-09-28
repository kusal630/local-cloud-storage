import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/pool_cipher.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/contributor.dart';
import 'pool_coordinator.dart';

/// The missing half of v2.4.0 feature 5: **files → chunks → contributors**.
///
/// `PoolCoordinator` moves opaque blobs; this is what turns a file into those
/// blobs and puts them back. Everything here is host-side only — a
/// contributor receives an opaque 64-hex id and ciphertext, never a file name
/// or a plaintext byte (CONSULT §6 control 8).
///
/// Chunk ids are `SHA-256(fileId || ':' || index)` (CONSULT §177), which buys
/// three things for free:
/// * **content-addressed placement** — the same slot always maps to the same
///   chunk id, so placement never has to be recomputed for an unchanged file;
/// * **idempotent re-upload** — re-protecting an unchanged file is a set of
///   no-ops instead of a second copy of everything;
/// * **no path traversal surface** — ids are derived, never taken from a
///   caller-supplied string.
class PoolStorage {
  PoolStorage({
    required Vault vault,
    required PoolCoordinator coordinator,
    PoolKeyStore? keyStore,
  }) : this._(
            vault,
            coordinator,
            keyStore ?? PoolKeyStore.standard(vaultDir: vault.vaultDir));

  const PoolStorage._(this._vault, this._coordinator, this._keyStore);

  final Vault _vault;
  final PoolCoordinator _coordinator;
  final PoolKeyStore _keyStore;

  /// 5 MiB: large enough that per-chunk HTTP and AEAD overhead stay in the
  /// noise (~0.1%), small enough that a repair pass after a device drops is
  /// seconds rather than minutes, and small enough that a single failed write
  /// costs little to redo.
  static const int chunkSize = 5 * 1024 * 1024;

  /// AAD for chunk encryption: `lv-chunk:<chunkId>`.
  ///
  /// A deviation from CONSULT §5.2 (`chunkId ‖ contributorId ‖ epoch`) with a
  /// reason: one ciphertext is replicated **verbatim** to R devices, so it
  /// cannot name a contributor, and the epoch changes whenever membership
  /// moves — binding it would invalidate every stored chunk the first time
  /// someone joined. Binding the chunk id still makes a blob useless at any
  /// other address, which is the property the AAD is for.
  static String aadFor(String chunkId) => 'lv-chunk:$chunkId';

  /// The chunk id protecting slot [index] of [fileId].
  static String chunkIdFor(String fileId, int index) =>
      Cipher.sha256String('$fileId:$index');

  /// Chunk ids in slot order for [fileId].
  List<String> chunkIdsFor(String fileId, int byteLength) {
    final count = byteLength == 0 ? 1 : ((byteLength + chunkSize - 1) ~/ chunkSize);
    return [for (var i = 0; i < count; i++) chunkIdFor(fileId, i)];
  }

  Future<Uint8List> _chunkKey(String chunkId) async => PoolCipher.deriveChunkKey(
        // The master KEK is the root of the host's key hierarchy. HKDF's
        // `info` label separates this from `contrib-secret-wrap`, so chunk
        // keys and wrap keys are unrelated outputs of the same secret.
        pairingSecret: await _keyStore.getMasterKek(),
        chunkId: chunkId,
      );

  /// Protects [bytes] in the pool, split into [chunkSize] chunks.
  ///
  /// Never throws because *part* of a file failed: a partial upload is a real
  /// and recoverable state ("pending repair", FEATURES §5 case 2) and the
  /// report says exactly which slots are missing. It throws only when nothing
  /// at all could be stored, so an empty success can never be mistaken for a
  /// protected file.
  Future<PoolWriteReport> putFile({
    required String fileId,
    required List<int> bytes,
    void Function(int completed, int total)? onProgress,
  }) async {
    if (fileId.isEmpty) {
      throw ArgumentError.value(fileId, 'fileId', 'must not be empty');
    }
    final count =
        bytes.isEmpty ? 1 : ((bytes.length + chunkSize - 1) ~/ chunkSize);

    // Record the intent FIRST. If this writer dies halfway, the ledger still
    // knows the file should have `count` slots, so a reader can tell
    // "2 of 3" from "3 of 3" instead of trusting whichever rows survived.
    _vault.contributors.upsertFileMeta(
      fileId: fileId,
      chunkCount: count,
      byteLength: bytes.length,
    );
    await _detachTail(fileId, count);

    var stored = 0;
    var underReplicated = false;
    var storedBytes = 0;
    final failed = <int>[];
    final skipped = <int>[];

    for (var seq = 0; seq < count; seq++) {
      final start = seq * chunkSize;
      final end = bytes.isEmpty
          ? 0
          : (start + chunkSize > bytes.length
              ? bytes.length
              : start + chunkSize);
      final slice = bytes.isEmpty ? const <int>[] : bytes.sublist(start, end);
      final chunkId = chunkIdFor(fileId, seq);
      final contentSha = sha256.convert(slice).toString();

      try {
        // Same slot, same bytes already protected → nothing to do. This is
        // what makes "protect this folder again" cheap instead of a full
        // re-upload of everything.
        final existing = _vault.contributors.recordedChunk(chunkId);
        if (existing != null && existing.contentSha256 == contentSha) {
          skipped.add(seq);
          stored++;
          storedBytes += existing.bytes;
          underReplicated = underReplicated ||
              _coordinator.usableCopies(chunkId) < _coordinator.replication;
          onProgress?.call(seq + 1, count);
          continue;
        }
        if (existing != null) {
          // The slot's content changed: drop the stale copy first so no device
          // is left holding bytes no manifest points at.
          await _coordinator.deleteChunk(chunkId);
        }

        final ciphertext = await PoolCipher.encryptChunk(
          key: await _chunkKey(chunkId),
          plaintext: slice,
          aad: aadFor(chunkId),
        );
        final result = await _coordinator.writeChunk(
          chunkId: chunkId,
          ciphertext: ciphertext,
          contentSha256: contentSha,
          idempotencyKey: 'file:$fileId:$seq:$contentSha',
          fileId: fileId,
          seq: seq,
        );
        stored++;
        storedBytes += ciphertext.length;
        if (result.replicaIds.length < _coordinator.replication) {
          underReplicated = true;
        }
      } catch (e, st) {
        failed.add(seq);
        logWarn('Pool write failed for $fileId#$seq: $e');
        logDebug('pool storage stack: $st');
      }
      onProgress?.call(seq + 1, count);
    }

    final report = PoolWriteReport(
      fileId: fileId,
      chunkCount: count,
      storedChunks: stored,
      protectedBytes: storedBytes,
      failedSequences: failed,
      skippedSequences: skipped,
      underReplicated: underReplicated,
    );
    if (report.storedChunks == 0) {
      throw ConflictException(
        'The pool refused every chunk of this file '
        '(${failed.length} of $count failed). Check that at least one device '
        'is online and has quota left, then try again.',
      );
    }
    logInfo(
      'Pool: $fileId ${report.isComplete ? 'protected' : 'partially protected'} '
      '(${report.storedChunks}/$count chunks, '
      '${failed.length} failed, '
      '${underReplicated ? 'below R=${_coordinator.replication}' : 'redundant'})',
    );
    return report;
  }

  /// Unlinks the slots a shrunken file no longer owns.
  ///
  /// Without this, a file that went from 5 chunks to 3 would leave slots 3 and
  /// 4 in the manifest — and the reader, seeing them, would append them after
  /// the new last chunk and hand back a silently corrupt file. Unlink first
  /// (plain SQL, cannot fail), then ask the devices to delete the bytes; an
  /// offline device keeps them until it returns, which is a quota question the
  /// maintenance sweep picks up, never a correctness one.
  Future<void> _detachTail(String fileId, int count) async {
    final stale = _vault.contributors
        .chunksForFile(fileId)
        .where((c) => c.seq >= count)
        .toList(growable: false);
    for (final chunk in stale) {
      _vault.contributors.detachChunk(chunk.chunkId);
      await _coordinator.deleteChunk(chunk.chunkId);
    }
  }

  /// Reads [fileId] back out of the pool.
  ///
  /// Returns `null` when the file was never protected. A result with
  /// `isComplete == false` means part of it could not be assembled — it is
  /// **never** silently truncated, because a short read that looks like a
  /// complete file is the worst failure a storage system can have.
  Future<PoolReadResult?> getFile(String fileId) async {
    final meta = _vault.contributors.fileMeta(fileId);
    if (meta == null) return null;

    final rows = _vault.contributors.chunksForFile(fileId);
    final bySeq = <int, PoolChunk>{for (final row in rows) row.seq: row};

    // Slots that were never written at all (an interrupted protect) are just
    // as missing as slots whose device is offline — count them before doing
    // any network so a hole in the manifest cannot look like a whole file.
    final missing = <int>[
      for (var seq = 0; seq < meta.chunkCount; seq++)
        if (!bySeq.containsKey(seq)) seq
    ];

    final builder = BytesBuilder(copy: false);
    var degraded = false;

    for (var seq = 0; seq < meta.chunkCount; seq++) {
      final chunk = bySeq[seq];
      if (chunk == null) continue;
      final read = await _coordinator.readChunk(chunk.chunkId);
      if (read == null) {
        missing.add(seq);
        continue;
      }
      Uint8List plaintext;
      try {
        plaintext = await PoolCipher.decryptChunk(
          key: await _chunkKey(chunk.chunkId),
          data: read.bytes,
          aad: aadFor(chunk.chunkId),
        );
      } on PoolCryptoException catch (e) {
        // The ciphertext matched the hash the host recorded but not the GCM
        // tag — the record itself is wrong. Refuse the data rather than hand
        // back bytes nobody can vouch for.
        logError('Pool: chunk ${chunk.chunkId} failed AEAD verification: $e');
        missing.add(seq);
        continue;
      }
      if (!PoolCipher.verifyPlaintextSha256(plaintext, chunk.contentSha256)) {
        logError('Pool: chunk ${chunk.chunkId} plaintext hash mismatch');
        missing.add(seq);
        continue;
      }
      if (read.degraded) degraded = true;
      builder.add(plaintext);
    }

    if (missing.isNotEmpty) {
      missing.sort();
      return PoolReadResult(
        bytes: const [],
        chunkCount: meta.chunkCount,
        missingSequences: missing,
        degraded: true,
      );
    }
    return PoolReadResult(
      bytes: builder.takeBytes(),
      chunkCount: meta.chunkCount,
      missingSequences: const [],
      degraded: degraded,
    );
  }

  /// Releases every device's copy of [fileId] and gives the quota back.
  ///
  /// Returns how many chunks are definitively gone. Anything still held (an
  /// offline device that will confirm when it returns) is reported rather
  /// than assumed deleted — "deleted" is a claim only the holder can make.
  Future<PoolDeleteReport> deleteFile(String fileId) async {
    final meta = _vault.contributors.fileMeta(fileId);
    final chunks = _vault.contributors.chunksForFile(fileId);
    // The tail of a shrunken file belongs to nobody already; finish releasing
    // it so this delete really does free everything the file ever claimed.
    await _detachTail(fileId, 0);

    var released = 0;
    var pending = 0;
    for (final chunk in chunks) {
      if (await _coordinator.deleteChunk(chunk.chunkId)) {
        released++;
      } else {
        pending++;
      }
    }
    if (pending == 0) {
      _vault.contributors.deleteChunksForFile(fileId);
      _vault.contributors.deleteFileMeta(fileId);
    } else {
      // Keep the expectation record: reads must keep reporting this file as
      // incomplete until the last device confirms, not as gone.
      logInfo(
        'Pool: $fileId delete pending on $pending of ${meta?.chunkCount ?? chunks.length} chunks',
      );
    }
    return PoolDeleteReport(
      chunkCount: meta?.chunkCount ?? chunks.length,
      released: released,
      pending: pending,
    );
  }

  /// Ledger view of one file — no network, safe to call from a list builder.
  PoolFileStatus statusOf(String fileId) {
    final meta = _vault.contributors.fileMeta(fileId);
    if (meta == null) {
      return const PoolFileStatus(
        fileId: '',
        chunkCount: 0,
        storedChunks: 0,
        completeChunks: 0,
        bytes: 0,
        byteLength: 0,
        degraded: false,
      );
    }
    final rows = _vault.contributors.chunksForFile(fileId);
    final bySeq = <int, PoolChunk>{for (final row in rows) row.seq: row};
    var complete = 0;
    var stored = 0;
    var bytes = 0;
    var degraded = false;

    for (var seq = 0; seq < meta.chunkCount; seq++) {
      final chunk = bySeq[seq];
      if (chunk == null) {
        // Never landed — the loudest possible "this file is not whole".
        degraded = true;
        continue;
      }
      stored++;
      bytes += chunk.bytes;
      if (_coordinator.usableCopies(chunk.chunkId) >= _coordinator.replication) {
        complete++;
      } else {
        degraded = true;
      }
    }
    return PoolFileStatus(
      fileId: fileId,
      chunkCount: meta.chunkCount,
      storedChunks: stored,
      completeChunks: complete,
      bytes: bytes,
      byteLength: meta.byteLength,
      degraded: degraded,
    );
  }

  /// Files currently protected in the pool, oldest first.
  List<String> protectedFileIds() => _vault.contributors.protectedFileIds();
}

/// Outcome of [PoolStorage.putFile].
class PoolWriteReport {
  const PoolWriteReport({
    required this.fileId,
    required this.chunkCount,
    required this.storedChunks,
    required this.protectedBytes,
    required this.failedSequences,
    required this.skippedSequences,
    required this.underReplicated,
  });

  final String fileId;
  final int chunkCount;
  final int storedChunks;

  /// Ciphertext bytes written (or already present) — what the pool now holds.
  final int protectedBytes;

  /// Slots that could not be written at all.
  final List<int> failedSequences;

  /// Slots that were already protected with identical content.
  final List<int> skippedSequences;

  /// True when at least one stored chunk has fewer than R usable copies.
  final bool underReplicated;

  /// Every slot is present — the file is fully protected.
  bool get isComplete =>
      failedSequences.isEmpty && storedChunks == chunkCount;

  /// Stored, but some chunk is below R: survivable, and the UI must say so.
  bool get isDegraded => !isComplete || underReplicated;

  @override
  String toString() =>
      'PoolWriteReport($fileId: $storedChunks/$chunkCount chunks, '
      '${failedSequences.length} failed, '
      '${underReplicated ? 'degraded' : 'redundant'})';
}

/// Outcome of [PoolStorage.getFile].
class PoolReadResult {
  const PoolReadResult({
    required this.bytes,
    required this.chunkCount,
    required this.missingSequences,
    required this.degraded,
  });

  /// Reassembled plaintext. Empty when [isComplete] is false.
  final List<int> bytes;
  final int chunkCount;

  /// Slots that could not be fetched and verified. Never non-empty while
  /// [bytes] is populated: partial output is refused, not truncated.
  final List<int> missingSequences;

  /// Served from fewer than R copies somewhere along the way.
  final bool degraded;

  bool get isComplete => missingSequences.isEmpty;
}

/// Ledger view of one protected file — the numbers the UI shows, all derived
/// from what is actually recorded, with no optimistic arithmetic anywhere.
class PoolFileStatus {
  const PoolFileStatus({
    required this.fileId,
    required this.chunkCount,
    required this.storedChunks,
    required this.completeChunks,
    required this.bytes,
    required this.byteLength,
    required this.degraded,
  });

  final String fileId;

  /// Slots the file is SUPPOSED to have.
  final int chunkCount;

  /// Slots that actually have a manifest row (≤ [chunkCount]).
  final int storedChunks;

  /// Slots that currently hold R usable copies.
  final int completeChunks;

  /// Ciphertext bytes stored across the pool for this file.
  final int bytes;

  /// Plaintext length of the original file.
  final int byteLength;
  final bool degraded;

  bool get isProtected => chunkCount > 0;

  /// Every slot present AND at R: fully redundant.
  bool get isComplete => chunkCount > 0 && completeChunks == chunkCount;

  /// Some slot is missing entirely — the protect never finished.
  bool get isPending => storedChunks < chunkCount;
}

/// Outcome of [PoolStorage.deleteFile].
class PoolDeleteReport {
  const PoolDeleteReport({
    required this.chunkCount,
    required this.released,
    required this.pending,
  });

  final int chunkCount;
  final int released;

  /// Chunks still held by a device that did not confirm — quota stays
  /// claimed until it does, which is the honest accounting.
  final int pending;

  bool get isFullyReleased => pending == 0;
}
