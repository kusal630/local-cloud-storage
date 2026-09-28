import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/pool_cipher.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/contributor.dart';
import 'placement.dart';
import 'pool_node_client.dart';

/// Outcome of one reserve → hold → put → commit chain on a contributor.
enum PlacementOutcome {
  /// Chunk stored and the replica recorded as `STORED`.
  stored,

  /// This contributor had no room — the planner moves to the next candidate.
  noSpace,

  /// Transport / auth / verification failure — recorded as `last_error`.
  failed,

  /// The candidate list was exhausted before [ChunkWriteResult.replicas]
  /// reached the replication factor: the chunk exists but is `UNDER_REPLICATED`.
  noCandidates,
}

/// Result of writing one chunk into the pool.
class ChunkWriteResult {
  const ChunkWriteResult({
    required this.chunkId,
    required this.replicaIds,
    required this.outcomes,
    required this.bytes,
  });

  final String chunkId;

  /// Contributors that now hold a verified copy.
  final List<String> replicaIds;

  /// Per-candidate attempt results, in the order they were tried.
  final Map<String, PlacementOutcome> outcomes;

  final int bytes;

  bool get success => replicaIds.isNotEmpty;

  /// Written, but below the replication factor — reads work, repair is queued
  /// (the UI must say so, never look healthy: ZFS DEGRADED rule).
  bool isDegradedAgainst(int replication) =>
      success && replicaIds.length < replication;
}

/// Result of reading one chunk back out of the pool.
class ChunkReadResult {
  const ChunkReadResult({
    required this.chunkId,
    required this.bytes,
    required this.replicaCount,
    required this.sha256,
    this.replication = PoolPlacement.defaultReplication,
    this.quarantined = const [],
  });

  final String chunkId;
  final List<int> bytes;

  /// How many verified copies existed at read time (1 = degraded read).
  final int replicaCount;

  /// Host-recorded SHA-256 of the stored blob.
  final String sha256;

  /// Copies this read was supposed to have.
  final int replication;

  /// Contributors whose copy failed verification and was quarantined.
  final List<String> quarantined;

  /// True when this answer was thinner than it should be: fewer usable copies
  /// than [replication], **or** a copy was thrown out part-way through.
  /// Counting a quarantined copy as healthy would let the UI keep saying
  /// "redundant" while redundancy quietly evaporates.
  bool get degraded => replicaCount < replication || quarantined.isNotEmpty;
}

/// One consistent snapshot of the pool for the UI (CONSULT §4: every figure
/// is *derived* in one query inside one transaction, never accumulated).
class PoolSnapshot {
  const PoolSnapshot({
    required this.totalQuota,
    required this.usedBytes,
    required this.reservedBytes,
    required this.epoch,
    required this.health,
    required this.contributors,
    required this.chunkCount,
    required this.degradedChunks,
    required this.generatedAt,
  });

  final int totalQuota;
  final int usedBytes;
  final int reservedBytes;
  final int epoch;
  final PoolHealth health;
  final List<Contributor> contributors;
  final int chunkCount;
  final int degradedChunks;
  final DateTime generatedAt;

  int get availableQuota {
    var usable = 0;
    for (final c in contributors) {
      if (c.countsTowardPool) usable += c.quotaBytes;
    }
    return usable;
  }

  int get offlineQuota {
    var gone = 0;
    for (final c in contributors) {
      if (!c.countsTowardPool) gone += c.quotaBytes;
    }
    return gone;
  }

  int get freeBytes {
    final free = totalQuota - usedBytes - reservedBytes;
    return free < 0 ? 0 : free;
  }

  bool get quotaExceeded => totalQuota > 0 && freeBytes <= 0;

  Map<String, Object?> toJson({String? thisDeviceId}) => {
        'total_quota': totalQuota,
        'used_bytes': usedBytes,
        'reserved_bytes': reservedBytes,
        'available_quota': availableQuota,
        'offline_quota': offlineQuota,
        'free_bytes': freeBytes,
        'epoch': epoch,
        'health': health.label,
        'chunk_count': chunkCount,
        'degraded_chunks': degradedChunks,
        'quota_exceeded': quotaExceeded,
        'generated_at': generatedAt.toIso8601String(),
        'contributors': [
          for (final c in contributors) contributorJson(c, thisDeviceId),
        ],
      };

  static Map<String, Object?> contributorJson(
    Contributor c,
    String? thisDeviceId,
  ) =>
      {
        'id': c.id,
        'device_id': c.deviceId,
        'name': c.name,
        'status': c.status.dbValue,
        'quota_bytes': c.quotaBytes,
        'used_bytes': c.usedBytes,
        'free_bytes': c.freeBytes,
        'device_kind': c.deviceKind,
        'is_this_device': thisDeviceId != null && c.deviceId == thisDeviceId,
        'last_seen': c.lastHeartbeatAt.toIso8601String(),
        'endpoint': c.endpoint,
        'last_error': c.lastError,
      };
}

/// Headline pool state — the single colored word above everything on the
/// pool screen (ZFS `DEGRADED` / Ceph `health` vocabulary).
enum PoolHealth {
  /// Nobody contributing yet.
  empty('EMPTY'),

  /// Every contributor is counted and reachable.
  online('ONLINE'),

  /// ≥1 contributor offline but reads still repair from replicas.
  degraded('DEGRADED'),

  /// No redundancy left: 1 copy (or none) of at least one chunk.
  atRisk('AT_RISK'),

  /// Every contributor offline — the pool cannot be written to.
  offline('OFFLINE');

  const PoolHealth(this.label);

  final String label;

  static PoolHealth fromLabel(String raw) => PoolHealth.values.firstWhere(
        (h) => h.label == raw,
        orElse: () => PoolHealth.empty,
      );
}

/// Registration handshake result (CONSULT §1).
class PoolRegistration {
  const PoolRegistration({
    required this.contributorId,
    required this.token,
    required this.expiresAt,
    required this.heartbeatInterval,
    required this.epoch,
  });

  final String contributorId;

  /// 256-bit capability token, returned exactly once over pinned TLS.
  final String token;
  final DateTime expiresAt;
  final Duration heartbeatInterval;
  final int epoch;

  Map<String, Object?> toJson() => {
        'contributor_id': contributorId,
        'token': token,
        'expires_at': expiresAt.toIso8601String(),
        'heartbeat_sec': heartbeatInterval.inSeconds,
        'epoch': epoch,
      };
}

/// Re-replication / audit work reports (the "resilver row" in the UI).
class RepairReport {
  const RepairReport({
    this.repaired = 0,
    this.queued = 0,
    this.failed = 0,
    this.quarantined = 0,
  });

  final int repaired;
  final int queued;
  final int failed;
  final int quarantined;

  bool get didWork => repaired > 0 || failed > 0 || quarantined > 0;
}

/// The pool coordinator: registry, liveness, admission control, placement,
/// verified reads and repair (RESEARCH/CONSULT.md §1–§6).
///
/// It is the single source of truth for everything the pool screen shows and
/// the only component that talks to contributor nodes — readers ask it for
/// locations rather than recomputing placement themselves (CONSULT §3).
class PoolCoordinator {
  PoolCoordinator({
    required Vault vault,
    PoolNodeClient? client,
    PoolKeyStore? keyStore,
    this.replication = PoolPlacement.defaultReplication,
    this.epochDebounce = defaultEpochDebounce,
  })  : _vault = vault,
        _client = client ?? PoolNodeClient(),
        _keyStore = keyStore ??
            PoolKeyStore.standard(vaultDir: vault.vaultDir);

  final Vault _vault;
  final PoolNodeClient _client;
  final PoolKeyStore _keyStore;
  final int replication;

  static const String _epochKey = 'pool_epoch';
  static const String _epochAtKey = 'pool_epoch_bumped_at';

  /// Default debounce for epoch bumps (§3: at most one bump per 30 s, and
  /// never more than one per 5 min — a sleeping phone must not cause epoch
  /// churn). Injectable so tests do not have to sleep for it.
  static const Duration defaultEpochDebounce = Duration(seconds: 30);

  /// Actual debounce used by this coordinator instance.
  final Duration epochDebounce;

  /// Capability-token lifetime; heartbeats refresh it (§1, §6 control 2).
  static const Duration tokenLifetime = Duration(hours: 24);

  static const Duration heartbeatInterval = Duration(seconds: 60);

  /// Gap between what a node claims it stores and what the ledger has paid
  /// for that is tolerated as normal jitter (staged-but-aborted bytes, a GC
  /// in flight) before it is surfaced as a storage mismatch.
  static const int driftToleranceBytes = 1024 * 1024;

  final Random _random = Random.secure();

  // ---------------------------------------------------------------------------
  // Opportunistic maintenance (no timer, no leak)
  // ---------------------------------------------------------------------------

  DateTime? _lastMaintenance;
  bool _maintenanceRunning = false;

  /// Runs one bounded pass of the background jobs at most once per [every].
  ///
  /// Deliberately driven by reads of the pool status instead of a
  /// `Timer.periodic`: the handler has no shutdown hook, so a timer would
  /// leak on every server restart, whereas this self-corrects the moment
  /// anyone looks at the pool screen (and runs nothing when nobody does).
  Future<void> maybeMaintenance({Duration every = const Duration(seconds: 60)}) async {
    if (_maintenanceRunning) return;
    final now = DateTime.now();
    if (_lastMaintenance != null && now.difference(_lastMaintenance!) < every) {
      return;
    }
    _maintenanceRunning = true;
    _lastMaintenance = now;
    try {
      await sweepLiveness();
      await repairStep(maxChunks: 8);
      await garbageCollect(maxChunks: 8);
      await auditStep(samples: 4);
    } catch (e) {
      logWarn('Pool maintenance pass failed: $e');
    } finally {
      _maintenanceRunning = false;
    }
  }

  /// Frees chunks that no file owns any more.
  ///
  /// Unlinking a slot from its file is instant because it has to be — the
  /// reader must stop seeing it immediately or it would corrupt the next
  /// reassembly. Reclaiming the bytes is not instant, because the only device
  /// that can confirm a delete is the one holding them, and it may be asleep.
  /// This keeps retrying until every holder has acknowledged, so a shrunken
  /// file can never leave quota claimed forever.
  Future<int> garbageCollect({int maxChunks = 8}) async {
    final queue = _vault.contributors.detachedChunkIds(limit: maxChunks);
    var purged = 0;
    for (final chunkId in queue) {
      try {
        if (await deleteChunk(chunkId)) purged++;
      } catch (e) {
        logWarn('Pool GC failed for $chunkId: $e');
      }
    }
    if (purged > 0) {
      _vault.mutated(
        action: 'pool.gc',
        detail: '$purged detached chunks freed',
      );
    }
    return purged;
  }

  // ---------------------------------------------------------------------------
  // Registry (CONSULT §1)
  // ---------------------------------------------------------------------------

  /// Registers (or re-registers) a contributor and issues its capability
  /// token. The plaintext token exists only in this response; SQLite keeps
  /// `SHA-256(token)` for inbound auth plus a master-KEK-wrapped copy for
  /// outbound node calls — never plaintext at rest.
  Future<PoolRegistration> register({
    required String deviceId,
    required String name,
    required int quotaBytes,
    required String endpoint,
    String? fingerprint,
    String deviceKind = 'phone',
    String? nonce,
  }) async {
    if (quotaBytes <= 0) {
      throw const ValidationException('quota_bytes must be greater than zero.');
    }
    if (!_validEndpoint(endpoint)) {
      throw const ValidationException(
          'endpoint must be an http(s) URL of this device.');
    }
    if (nonce != null && nonce.isNotEmpty && nonce.length <= 512) {
      if (!_vault.contributors.insertNonce(nonce)) {
        throw const ConflictException('Registration replayed — retry with a fresh nonce.');
      }
    }

    // Re-registration REUSES the row this device already owns (D3): minting
    // a fresh uuid per join would double-count its quota and leave a ghost row
    // whose old token still authenticates. Everything from this lookup to the
    // INSERT below is synchronous, so two concurrent joins from the same
    // device cannot both observe "no existing row".
    final existing = _vault.contributors.getByDeviceId(deviceId);
    final contributorId = existing?.id ?? const Uuid().v4();
    final token = _newToken();
    final expiresAt = DateTime.now().add(tokenLifetime);

    _vault.contributors.register(
      id: contributorId,
      deviceId: deviceId,
      name: name,
      quotaBytes: quotaBytes,
      tokenHash: Cipher.sha256String(token),
      scope: 'pool:read,pool:write,pool:report',
      tokenExpiresAt: expiresAt.millisecondsSinceEpoch,
      endpoint: endpoint,
      fingerprint: fingerprint,
      deviceKind: deviceKind,
    );
    // Rotating `token_hash` on the reused row kills the previous credential —
    // a re-join never leaves a token behind that still works.
    //
    // Wrapped only now: if the master KEK is unavailable the client gets a 500
    // and retries, and the retry finds this row by device id instead of
    // creating a second one.
    final wrapped = await _wrapToken(contributorId, token);
    _vault.contributors.secrets.putNodeToken(contributorId, wrapped);

    final epoch = await bumpEpoch(reason: 'join:$contributorId');
    _vault.mutated(
      deviceId: deviceId,
      action: 'pool.join',
      targetId: contributorId,
      targetName: name,
      detail: '${existing == null ? 'new' : 'rejoin'} quota=$quotaBytes '
          'endpoint=$endpoint',
    );
    return PoolRegistration(
      contributorId: contributorId,
      token: token,
      expiresAt: expiresAt,
      heartbeatInterval: heartbeatInterval,
      epoch: epoch,
    );
  }

  /// Validates an inbound contributor request and returns its row.
  /// Throws [AuthException] on a bad/expired token.
  Contributor authenticateContributor(String? token) {
    if (token == null || token.isEmpty) {
      throw const AuthException('Missing contributor token.');
    }
    final hash = Cipher.sha256String(token);
    for (final c in _vault.contributors.list()) {
      final stored = c.tokenHash;
      if (stored == null || stored.isEmpty) continue;
      if (!Cipher.constantTimeEquals(
          utf8.encode(stored), utf8.encode(hash))) {
        continue;
      }
      final expiry = c.tokenExpiresAt;
      if (expiry != null && expiry.isBefore(DateTime.now())) {
        throw const AuthException('Contributor token expired.');
      }
      if (c.status == ContributorStatus.revoked) {
        throw const AuthException('Contributor has been revoked.');
      }
      return c;
    }
    throw const AuthException('Invalid contributor token.');
  }

  /// Applies a heartbeat usage report. Reports are monotonic (`report_seq`)
  /// and time-bounded, which is what stops `used_bytes` double-counting (§4).
  Future<bool> heartbeat({
    required String contributorId,
    required int reportSeq,
    required int usedBytes,
    required int freeBytes,
  }) async {
    final applied = _vault.contributors.heartbeat(
      contributorId: contributorId,
      reportSeq: reportSeq,
      usedBytes: usedBytes,
      freeBytes: freeBytes,
    );
    if (applied) {
      await _extendToken(contributorId);
      _vault.contributors.clearLastError(contributorId);
      // The ledger and the node now both have a figure for "what is stored
      // here". They should agree; when they do not, say which two numbers
      // disagree instead of quietly picking one (D5).
      final row = _vault.contributors.getById(contributorId);
      final drift = (row.reportedUsedBytes - row.usedBytes).abs();
      if (drift > driftToleranceBytes) {
        _vault.contributors.setLastError(
          contributorId,
          'Storage mismatch: device reports '
          '${row.reportedUsedBytes} B, pool ledger has ${row.usedBytes} B.',
        );
        _vault.mutated(
          action: 'pool.usage_drift',
          targetId: contributorId,
          targetName: row.name,
          detail: 'reported=${row.reportedUsedBytes} ledger=${row.usedBytes}',
        );
      }
    }
    return applied;
  }

  /// Changes a contributor's quota cap. Membership-adjacent but *not* an
  /// epoch bump: weights are read live from the row (CONSULT §3).
  void setQuota(String contributorId, int quotaBytes) {
    if (quotaBytes <= 0) {
      throw const ValidationException('quota_bytes must be greater than zero.');
    }
    final before = _vault.contributors.getById(contributorId);
    final stored = before.usedBytes;
    if (quotaBytes < stored) {
      throw ConflictException(
        'Cannot set the quota below the $stored bytes already stored there.',
      );
    }
    _vault.contributors.setQuota(contributorId, quotaBytes);
    _vault.mutated(
      action: 'pool.quota',
      targetId: contributorId,
      targetName: before.name,
      detail: '$stored -> $quotaBytes',
    );
  }

  /// Corrects where the coordinator should call [contributorId]. Validated
  /// here rather than in the route so the audit entry and the write land in
  /// the same place (§6 control 3: every change is logged).
  void setEndpoint(String contributorId, {required String endpoint, String? fingerprint}) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ValidationException(
        'endpoint must be an absolute http(s) URL with a host and no query or fragment.',
      );
    }
    if (fingerprint != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint.trim().toLowerCase())) {
      throw const ValidationException(
        'fingerprint must be 64 lowercase hex characters (SHA-256 of the node certificate).',
      );
    }
    final before = _vault.contributors.getById(contributorId);
    _vault.contributors.setEndpoint(
      contributorId,
      endpoint.replaceAll(RegExp(r'/+$'), ''),
      fingerprint: fingerprint?.trim().toLowerCase(),
    );
    _vault.mutated(
      action: 'pool.endpoint',
      targetId: contributorId,
      targetName: before.name,
      detail: endpoint,
    );
  }

  /// Revokes a contributor: status flip + reservation rollback in ONE
  /// transaction, then queue re-replication of everything it held (§1 —
  /// chunks are never considered deleted until replacements verify).
  Future<RepairReport> revoke(String contributorId) async {
    final before = _vault.contributors.getById(contributorId);
    // Capture the call target BEFORE the status flip. `_targetFor` refuses
    // REVOKED contributors on purpose (nobody should be served by a revoked
    // node), which means a wipe issued *after* the flip silently does nothing
    // — the node keeps every byte and a token that still looks valid (D1).
    final target = await _targetFor(before);
    final held = _vault.contributors.listReplicasByContributor(contributorId);
    final revoked = _vault.contributors.revoke(contributorId);
    if (!revoked) return const RepairReport();
    await bumpEpoch(reason: 'revoke:$contributorId');
    _vault.mutated(
      action: 'pool.revoke',
      targetId: contributorId,
      targetName: before.name,
      detail: 'held=${held.length}',
    );
    // Best-effort: tell the node to wipe itself, then forget the credential it
    // was signed with. Neither blocks revocation nor the HTTP response — the
    // caller reports the backlog ("revoking… re-replicating N chunks") and
    // repair drains in the background (§1 pitfall: revocation is not instant,
    // and must never look like it deleted data before the replacements
    // verified).
    if (target != null) {
      unawaited(_wipeAndForget(contributorId, target));
    }
    unawaited(_backgroundRepair('revoke:$contributorId'));
    return RepairReport(queued: held.length);
  }

  /// Drains the repair queue off the request path; failures are already
  /// recorded per chunk by [repairStep].
  Future<void> _backgroundRepair(String reason) async {
    try {
      final report = await repairStep(maxChunks: 64);
      if (report.didWork) {
        logInfo('Background repair ($reason): $report');
      }
    } catch (e) {
      logWarn('Background repair ($reason) failed: $e');
    }
  }

  /// Voluntary leave: the contributor stops counting at once (§4 — totals are
  /// derived, so no subtract step exists to get wrong).
  Future<RepairReport> leave(String contributorId) async {
    final before = _vault.contributors.getById(contributorId);
    if (!_vault.contributors.markLeft(contributorId)) {
      return const RepairReport();
    }
    await bumpEpoch(reason: 'leave:$contributorId');
    _vault.mutated(
      action: 'pool.leave',
      targetId: contributorId,
      targetName: before.name,
    );
    final held = _vault.contributors.listReplicasByContributor(contributorId);
    unawaited(_backgroundRepair('leave:$contributorId'));
    return RepairReport(queued: held.length);
  }

  // ---------------------------------------------------------------------------
  // Liveness (§1 — the host is the sole liveness authority)
  // ---------------------------------------------------------------------------

  /// Applies the §1 thresholds and bumps the epoch (debounced) when
  /// membership actually changed.
  Future<List<Contributor>> sweepLiveness({DateTime? now}) async {
    final changed = _vault.contributors.sweepLiveness(now: now);
    if (changed.isNotEmpty) {
      await bumpEpoch(
        reason: 'liveness:${changed.map((c) => c.id).join(',')}',
      );
      _vault.mutated(
        action: 'pool.liveness',
        detail: changed
            .map((c) => '${c.name}:${c.status.dbValue}')
            .join(', '),
      );
    }
    _vault.contributors.sweepExpiredReservations();
    _vault.contributors.sweepNonces();
    return changed;
  }

  // ---------------------------------------------------------------------------
  // Snapshot / status (§4)
  // ---------------------------------------------------------------------------

  /// One derived snapshot: totals, health headline and every contributor row
  /// computed from a single consistent view (CONSULT §4).
  ///
  /// All four reads share one read transaction so a device flipping
  /// `ALIVE → DEAD` mid-poll cannot yield a ring whose centre number includes
  /// a row the list already calls dead — and so the poll never asks for the
  /// write lock (see [VaultDatabase.withReadTransaction]).
  PoolSnapshot snapshot({String? thisDeviceId}) {
    return _vault.database.withReadTransaction(() {
      final totals = _vault.contributors.poolTotals();
      final contributors = _vault.contributors.list();
      final counted = contributors
          .where((c) => c.countsTowardPool)
          .toList(growable: false);
      final degradedChunks = _vault.contributors
          .underReplicatedChunks(targetReplicas: replication)
          .length;
      final chunkCount = _vault.contributors.countReplicas();

      return PoolSnapshot(
        totalQuota: totals.totalQuota,
        usedBytes: totals.usedBytes,
        reservedBytes: totals.reservedBytes,
        epoch: currentEpoch,
        health: _healthFor(contributors, counted, degradedChunks),
        contributors: contributors,
        chunkCount: chunkCount,
        degradedChunks: degradedChunks,
        generatedAt: DateTime.now(),
      );
    });
  }

  PoolHealth _healthFor(
    List<Contributor> all,
    List<Contributor> counted,
    int degradedChunks,
  ) {
    if (all.isEmpty) return PoolHealth.empty;
    if (counted.isEmpty) return PoolHealth.offline;
    if (degradedChunks > 0) return PoolHealth.atRisk;
    if (counted.length != all.length) return PoolHealth.degraded;
    return PoolHealth.online;
  }

  // ---------------------------------------------------------------------------
  // Placement epoch (§3)
  // ---------------------------------------------------------------------------

  int get currentEpoch =>
      int.tryParse(_vault.settings.get(_epochKey) ?? '') ?? 1;

  /// Bumps the placement epoch on membership change, debounced so a phone
  /// sleeping past the DEAD threshold cannot cause epoch churn (§3 pitfall).
  Future<int> bumpEpoch({required String reason}) async {
    final now = DateTime.now();
    final lastRaw = _vault.settings.get(_epochAtKey);
    final last = lastRaw == null ? null : DateTime.tryParse(lastRaw);
    if (last != null && now.difference(last) < epochDebounce) {
      return currentEpoch;
    }
    final next = currentEpoch + 1;
    _vault.settings.set(_epochKey, '$next');
    _vault.settings.set(_epochAtKey, now.toIso8601String());
    logInfo('Pool epoch -> $next ($reason)');
    return next;
  }

  // ---------------------------------------------------------------------------
  // Chunk write path (§2 + §3 + §6)
  // ---------------------------------------------------------------------------

  /// Writes one already-encrypted chunk into the pool:
  /// reserve → hold → put → commit on each target, in candidate order.
  ///
  /// The ledger reservation is the admission control (§2); the node's own
  /// hold is a second, independent check on the contributor's disk (§5.4).
  /// A candidate that refuses never aborts the write — the planner just
  /// moves to the next one.
  Future<ChunkWriteResult> writeChunk({
    required String chunkId,
    required List<int> ciphertext,
    required String contentSha256,
    required String idempotencyKey,
    String? fileId,
    int seq = 0,
  }) async {
    validateChunkId(chunkId);
    final cipherSha = sha256.convert(ciphertext).toString();
    final candidates = _eligibleContributors();
    final ranked = PoolPlacement.rankedIds(chunkId, candidates);
    final outcomes = <String, PlacementOutcome>{};
    final stored = <String>[];

    for (final id in ranked) {
      if (stored.length >= replication) break;
      final contributor = _vault.contributors.getById(id);
      final outcome = await _placeOn(
        contributor: contributor,
        chunkId: chunkId,
        ciphertext: ciphertext,
        cipherSha256: cipherSha,
        contentSha256: contentSha256,
        idempotencyKey: idempotencyKey,
        fileId: fileId,
        seq: seq,
      );
      outcomes[id] = outcome;
      if (outcome == PlacementOutcome.stored) stored.add(id);
    }

    if (stored.isEmpty) {
      // Make the refusal answerable: which reason dominated?
      final reason = outcomes.values.contains(PlacementOutcome.noSpace)
          ? 'Pool full — no contributor has room for '
              '${ciphertext.length} bytes. Free space, raise a quota, or add a device.'
          : candidates.isEmpty
              ? 'No contributor is online right now.'
              : 'Every contributor refused the write.';
      _vault.mutated(
        action: 'chunk.write.fail',
        targetId: chunkId,
        detail: reason,
      );
      throw ConflictException(reason);
    }

    if (stored.length < replication) {
      _vault.mutated(
        action: 'chunk.under_replicated',
        targetId: chunkId,
        detail: '${stored.length}/$replication copies',
      );
    }
    return ChunkWriteResult(
      chunkId: chunkId,
      replicaIds: stored,
      outcomes: outcomes,
      bytes: ciphertext.length,
    );
  }

  Future<PlacementOutcome> _placeOn({
    required Contributor contributor,
    required String chunkId,
    required List<int> ciphertext,
    required String cipherSha256,
    required String contentSha256,
    required String idempotencyKey,
    String? fileId,
    int seq = 0,
  }) async {
    final bytes = ciphertext.length;

    // 1. Ledger reservation (§2) — the oversubscription invariant.
    Reservation? reservation;
    try {
      reservation = _vault.contributors.reserveChunk(
        idempotencyKey,
        chunkId,
        contributor.id,
        bytes,
      );
    } on NotFoundException {
      return PlacementOutcome.failed;
    } on ConflictException {
      // The contributor stopped being ALIVE between the candidate listing and
      // this attempt — a heartbeat or a revoke can do that at any instant.
      // That is a normal outcome, not a write failure: record why and let the
      // caller place on the next candidate instead of failing the whole write
      // (D4).
      _vault.contributors.setLastError(
        contributor.id,
        'Left the pool before this write could be placed.',
      );
      return PlacementOutcome.failed;
    }
    if (reservation == null) return PlacementOutcome.noSpace;

    // Idempotent retry (D15): this exact write already went through. Replaying
    // hold/put/commit would double-count the bytes on the node *and* in the
    // ledger, so the correct answer is simply "stored".
    if (reservation.state == ReservationState.committed) {
      return PlacementOutcome.stored;
    }

    final target = await _targetFor(contributor);
    if (target == null) {
      _vault.contributors.rollbackReservation(idempotencyKey, contributor.id);
      return PlacementOutcome.failed;
    }

    // 2. Contributor-side hold (§5.4) — its cap is authoritative for itself.
    final hold = await _client.hold(
      target,
      idempotencyKey: idempotencyKey,
      chunkId: chunkId,
      bytes: bytes,
    );
    if (!hold.ok) {
      _vault.contributors.rollbackReservation(idempotencyKey, contributor.id);
      _noteContributorError(contributor.id, hold);
      return hold.isNoSpace ? PlacementOutcome.noSpace : PlacementOutcome.failed;
    }

    // 3. PUT the ciphertext.
    final put = await _client.put(
      target,
      idempotencyKey: idempotencyKey,
      chunkId: chunkId,
      payload: ciphertext,
      sha256Hex: cipherSha256,
    );
    if (!put.ok) {
      await _client.abort(target, idempotencyKey: idempotencyKey);
      _vault.contributors.rollbackReservation(idempotencyKey, contributor.id);
      _noteContributorError(contributor.id, put);
      return put.isNoSpace ? PlacementOutcome.noSpace : PlacementOutcome.failed;
    }

    // 4. COMMIT on the contributor (verifies the bytes it actually holds).
    final commit = await _client.commit(
      target,
      idempotencyKey: idempotencyKey,
      chunkId: chunkId,
      sha256: cipherSha256,
    );
    if (!commit.ok) {
      await _client.abort(target, idempotencyKey: idempotencyKey);
      await _client.delete(target, chunkId).catchError((_) => NodeCall.unavailable);
      _vault.contributors.rollbackReservation(idempotencyKey, contributor.id);
      _noteContributorError(contributor.id, commit);
      return commit.isNoSpace ? PlacementOutcome.noSpace : PlacementOutcome.failed;
    }

    // 5. Ledger commit: reservation -> COMMITTED, replica -> STORED,
    //    `used_bytes` += bytes. One transaction (§2, §4).
    final committed = _vault.contributors.commitReservation(
      idempotencyKey,
      contributor.id,
      cipherSha256,
    );
    if (!committed) {
      // The row was swept out from under us: the bytes are on disk but the
      // ledger does not own them yet. Adopt them — replica row AND the
      // matching `used_bytes` in one transaction — so the chunk is never
      // invisible to repair and the copy is never unpaid for (D6).
      _vault.contributors.adoptOrphanReplica(
        chunkId: chunkId,
        contributorId: contributor.id,
        sha256: cipherSha256,
        bytes: bytes,
      );
    }
    _vault.contributors.recordChunk(
      chunkId: chunkId,
      bytes: bytes,
      contentSha256: contentSha256,
      cipherSha256: cipherSha256,
      fileId: fileId,
      seq: seq,
    );
    _vault.contributors.clearLastError(contributor.id);
    return PlacementOutcome.stored;
  }

  // ---------------------------------------------------------------------------
  // Chunk read path (§6 control 1)
  // ---------------------------------------------------------------------------

  /// Reads a chunk, trying replicas in preference order and verifying every
  /// byte against the SHA-256 the *host* recorded at commit time. A mismatch
  /// quarantines that copy (`CORRUPT`) — never deletes the only good one —
  /// and the next replica is tried.
  Future<ChunkReadResult?> readChunk(String chunkId) async {
    validateChunkId(chunkId);
    final replicas = _readableReplicas(chunkId);
    final quarantined = <String>[];
    for (final replica in replicas) {
      final contributor = _vault.contributors.getById(replica.contributorId);
      final target = await _targetFor(contributor);
      if (target == null) continue;
      final call = await _client.get(target, chunkId);
      if (!call.ok || call.bytes == null) {
        _noteContributorError(contributor.id, call);
        continue;
      }
      final actual = sha256.convert(call.bytes!).toString();
      if (!_constantTimeHex(actual, replica.sha256)) {
        _vault.contributors.upsertReplica(
          chunkId,
          contributor.id,
          ReplicaState.corrupt,
          replica.sha256,
          replica.bytes,
        );
        quarantined.add(contributor.id);
        _vault.mutated(
          action: 'chunk.read.corrupt',
          targetId: chunkId,
          targetName: contributor.name,
          detail: 'expected ${replica.sha256}, got $actual',
        );
        continue;
      }
      _vault.contributors.clearLastError(contributor.id);
      return ChunkReadResult(
        chunkId: chunkId,
        bytes: call.bytes!,
        replicaCount: replicas.length,
        sha256: replica.sha256,
        replication: replication,
        quarantined: quarantined,
      );
    }
    if (quarantined.isNotEmpty) {
      unawaited(repairStep(maxChunks: 4));
    }
    return null;
  }

  /// Replica locations for [chunkId], healthiest first — the answer readers
  /// ask for instead of recomputing placement (CONSULT §3).
  List<String> locations(String chunkId) =>
      _readableReplicas(chunkId).map((r) => r.contributorId).toList();

  /// How many devices could actually serve [chunkId] right now.
  ///
  /// "Right now" is deliberate: a copy sitting on a dead, left or revoked
  /// device exists on disk but cannot be read, so it is not redundancy the
  /// caller can lean on. This is the number the UI's per-file protection
  /// state is built from — if it is below [replication], the file is genuinely
  /// one failure away from being unreadable and should say so.
  int usableCopies(String chunkId) => _readableReplicas(chunkId).length;

  List<ChunkReplica> _readableReplicas(String chunkId) {
    final rows = _vault.contributors
        .listReplicas(chunkId)
        .where((r) =>
            r.state == ReplicaState.stored || r.state == ReplicaState.degraded)
        .toList();
    rows.sort((a, b) {
      final ca = _vault.contributors.getById(a.contributorId);
      final cb = _vault.contributors.getById(b.contributorId);
      final alive = (cb.countsTowardPool ? 1 : 0) - (ca.countsTowardPool ? 1 : 0);
      if (alive != 0) return alive;
      final aa = ca.countsTowardPool && ca.isReachable ? 1 : 0;
      final ab = cb.countsTowardPool && cb.isReachable ? 1 : 0;
      if (aa != ab) return ab - aa;
      return (b.updatedAt?.millisecondsSinceEpoch ?? 0) -
          (a.updatedAt?.millisecondsSinceEpoch ?? 0);
    });
    return rows
        .where((r) {
          final c = _vault.contributors.getById(r.contributorId);
          return c.countsTowardPool && c.isReachable;
        })
        .toList(growable: false);
  }

  // ---------------------------------------------------------------------------
  // Repair (§3 + FEATURES §5.1 — copy before delete, always)
  // ---------------------------------------------------------------------------

  /// One bounded pass over the repair queue: every chunk below the
  /// replication factor gets a new copy from a surviving one.
  ///
  /// Ordering is deliberate — the replacement is written and verified first;
  /// only then is the dead contributor's row dropped. A crash mid-repair
  /// leaves two copies, never one.
  /// One repair pass at a time (D16).
  ///
  /// Four callers race for this: the maintenance pass, the background drain
  /// after a revoke, the quarantine path inside `readChunk`, and the manual
  /// "check pool health" route. Without the flag they would each reserve the
  /// same chunks, so the same copy gets written twice and the report
  /// double-counts work nobody asked for.
  bool _repairRunning = false;

  Future<RepairReport> repairStep({int maxChunks = 8}) async {
    if (_repairRunning) return const RepairReport();
    _repairRunning = true;
    try {
      final queue = _vault.contributors
          .underReplicatedChunks(targetReplicas: replication)
          .take(maxChunks);
      var repaired = 0;
      var failed = 0;

      for (final chunkId in queue) {
        try {
          final ok = await _repairChunk(chunkId);
          if (ok) {
            repaired++;
          } else {
            failed++;
          }
        } catch (e, st) {
          logWarn('Repair failed for $chunkId: $e');
          logDebug('repair stack: $st');
          failed++;
        }
      }
      return RepairReport(
        repaired: repaired,
        failed: failed,
        queued: _vault.contributors
            .underReplicatedChunks(targetReplicas: replication)
            .length,
      );
    } finally {
      _repairRunning = false;
    }
  }

  Future<bool> _repairChunk(String chunkId) async {
    final replicas = _vault.contributors.listReplicas(chunkId);
    final live = replicas
        .where((r) => r.state == ReplicaState.stored && _holderUsable(r))
        .toList();
    final dead = replicas
        .where((r) => (r.state == ReplicaState.stored ||
                r.state == ReplicaState.degraded) &&
            !_holderUsable(r))
        .toList();
    if (live.length >= replication) {
      // Enough healthy copies already — retire the dead rows now that
      // replacements are verified (copy-before-delete satisfied).
      for (final row in dead) {
        // Release (not a bare state flip): the bytes this device was holding
        // were paid for at commit, and a retired copy has to give the quota
        // back or the device's usage creeps upward forever.
        _vault.contributors.releaseReplica(chunkId, row.contributorId);
      }
      return true;
    }
    if (live.isEmpty) return false;

    final source = await readChunk(chunkId);
    if (source == null) return false;

    final holders = replicas.map((r) => r.contributorId).toSet();
    final candidates = _eligibleContributors()
        .where((c) => !holders.contains(c.id))
        .toList(growable: false);
    if (candidates.isEmpty) return false;

    final ranked = PoolPlacement.rankedIds(chunkId, candidates);
    for (final id in ranked) {
      final result = await writeChunk(
        chunkId: chunkId,
        ciphertext: source.bytes,
        contentSha256: _vault.contributors
                .recordedChunk(chunkId)?.contentSha256 ??
            sha256.convert(source.bytes).toString(),
        idempotencyKey: 'repair:$chunkId:$id',
      );
      if (result.success) {
        for (final row in dead) {
          // Release rather than a bare state flip: those bytes were paid for
          // at commit, and a retired copy that never gives its quota back
          // makes a device's usage creep upward forever. Same rule as the
          // "enough healthy copies" branch above.
          _vault.contributors.releaseReplica(chunkId, row.contributorId);
        }
        _vault.mutated(
          action: 'chunk.repair',
          targetId: chunkId,
          detail: '${source.bytes.length} bytes -> ${result.replicaIds.join(', ')}',
        );
        return true;
      }
    }
    return false;
  }

  /// Probabilistic spot-audit (Storj/Ceph scrub): fetch sampled `STORED`
  /// copies and re-verify them against the host-recorded hash. Mismatches
  /// quarantine the copy and feed the security score.
  Future<RepairReport> auditStep({int samples = 5}) async {
    final pool = _vault.contributors.sampleReplicas(samples, _random);
    var quarantined = 0;
    for (final replica in pool) {
      final contributor = _vault.contributors.getById(replica.contributorId);
      if (!contributor.countsTowardPool || !contributor.isReachable) continue;
      final target = await _targetFor(contributor);
      if (target == null) continue;
      final call = await _client.get(target, replica.chunkId);
      if (!call.ok || call.bytes == null) {
        _noteContributorError(contributor.id, call);
        continue;
      }
      final actual = sha256.convert(call.bytes!).toString();
      if (!_constantTimeHex(actual, replica.sha256)) {
        _vault.contributors.upsertReplica(
          replica.chunkId,
          contributor.id,
          ReplicaState.corrupt,
          replica.sha256,
          replica.bytes,
        );
        quarantined++;
        _vault.mutated(
          action: 'chunk.audit.corrupt',
          targetId: replica.chunkId,
          targetName: contributor.name,
          detail: 'spot-audit mismatch',
        );
      }
    }
    if (quarantined > 0) await repairStep(maxChunks: 4);
    return RepairReport(quarantined: quarantined);
  }

  bool _holderUsable(ChunkReplica replica) {
    final c = _vault.contributors.getById(replica.contributorId);
    return c.countsTowardPool && c.isReachable;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Contributors eligible to receive placements.
  List<PlacementCandidate> _eligibleContributors() {
    final now = DateTime.now();
    return [
      for (final c in _vault.contributors.placementCandidates())
        PlacementCandidate(
          id: c.id,
          freeBytes: _usableFreeBytes(c, now),
          quotaBytes: c.quotaBytes,
          usedBytes: c.usedBytes,
        ),
    ];
  }

  /// Free space the planner may weight on: the smaller of what the
  /// contributor claims and what is left inside its own cap (§6 control 3 —
  /// `free_bytes` only ever weights, the ledger admits).
  int _usableFreeBytes(Contributor c, DateTime now) {
    final capLeft = c.quotaBytes - c.usedBytes;
    final claimed = c.freeBytes > 0 ? c.freeBytes : capLeft;
    return claimed < capLeft ? claimed : capLeft;
  }

  Future<NodeTarget?> _targetFor(Contributor contributor) async {
    final endpoint = contributor.endpoint;
    if (endpoint == null || endpoint.isEmpty) return null;
    if (contributor.status == ContributorStatus.revoked) return null;
    final token = await _nodeToken(contributor.id);
    if (token == null) return null;
    return NodeTarget(
      baseUrl: endpoint.replaceAll(RegExp(r'/+$'), ''),
      token: token,
      fingerprint: contributor.fingerprint,
    );
  }

  /// Best-effort wipe of a node that is being revoked.
  ///
  /// [target] was resolved before the status flip (see [revoke]); only the
  /// outbound credential is dropped, and only on an acknowledged wipe — a node
  /// that declined must stay re-wipeable, and its wrapped token is ciphertext
  /// under the master KEK either way.
  Future<void> _wipeAndForget(String contributorId, NodeTarget target) async {
    try {
      final call = await _client.wipe(target);
      if (!call.ok) {
        logWarn('Node wipe declined for $contributorId: '
            '${PoolNodeClient.describe(call)}');
        return;
      }
      _vault.contributors.secrets.deleteNodeToken(contributorId);
      _vault.mutated(
        action: 'pool.node_wiped',
        targetId: contributorId,
      );
    } catch (e) {
      logWarn('Node wipe failed for $contributorId: $e');
    }
  }

  void _noteContributorError(String contributorId, NodeCall call) {
    if (call.ok) return;
    _vault.contributors.setLastError(
      contributorId,
      PoolNodeClient.describe(call),
    );
  }

  /// Deletes a chunk from every device that holds it.
  ///
  /// Returns true only when **no copy of it survives anywhere**. A copy is
  /// released from the ledger exclusively when the node confirmed the delete
  /// (or the holder has already left the pool) — an unreachable-but-alive
  /// device keeps its row, because forgetting bytes we never actually removed
  /// is the one accounting mistake that cannot be recovered from.
  Future<bool> deleteChunk(String chunkId) async {
    validateChunkId(chunkId);
    final replicas = _vault.contributors
        .listReplicas(chunkId)
        .where((r) => r.state != ReplicaState.deleted)
        .toList(growable: false);

    var held = 0;
    for (final replica in replicas) {
      final contributor = _vault.contributors.getById(replica.contributorId);
      var released = false;
      final target = await _targetFor(contributor);
      if (target != null) {
        final call = await _client.delete(target, chunkId);
        released = call.ok || call.isMissing;
        if (!released) _noteContributorError(contributor.id, call);
      } else if (contributor.status == ContributorStatus.revoked ||
          contributor.status == ContributorStatus.left) {
        // The revoke path already wiped (or refused to) this node; the pool
        // will never read from it again, so its quota must not stay claimed.
        released = true;
      }
      final didRelease = released &&
          _vault.contributors.releaseReplica(chunkId, replica.contributorId);
      if (!didRelease) held++;
    }

    if (held > 0) return false;
    _vault.contributors.deleteChunkManifest(chunkId);
    _vault.mutated(action: 'chunk.deleted', targetId: chunkId);
    return true;
  }

  // --- Credentials ---------------------------------------------------------

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<Uint8List> _wrapToken(String contributorId, String token) async {
    final kek = await _keyStore.getMasterKek();
    // Domain separation: wrapping a *node token* must never be
    // interchangeable with wrapping a *pairing secret* (CONSULT §5
    // pitfall), so the AAD carries an explicit purpose label.
    return PoolCipher.wrapSecret(
      masterKek: kek,
      secret: utf8.encode(token),
      contributorId: 'node-token:$contributorId',
    );
  }

  Future<String?> _nodeToken(String contributorId) async {
    final stored = _vault.contributors.secrets.getNodeToken(contributorId);
    if (stored == null) return null;
    try {
      final kek = await _keyStore.getMasterKek();
      final plain = await PoolCipher.unwrapSecret(
        masterKek: kek,
        wrapped: stored,
        contributorId: 'node-token:$contributorId',
      );
      return utf8.decode(plain);
    } catch (e) {
      logWarn('Could not unwrap node token for $contributorId: $e');
      return null;
    }
  }

  Future<void> _extendToken(String contributorId) async {
    _vault.contributors.extendToken(
      contributorId,
      DateTime.now().add(tokenLifetime),
    );
  }

  // --- Validation ----------------------------------------------------------

  static final RegExp _chunkIdPattern = RegExp(r'^[0-9a-f]{64}$');

  static void validateChunkId(String chunkId) {
    if (!_chunkIdPattern.hasMatch(chunkId)) {
      throw const ValidationException(
          'chunk id must be 64 lowercase hex characters.');
    }
  }

  static bool _validEndpoint(String endpoint) {
    final uri = Uri.tryParse(endpoint);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    return true;
  }

  bool _constantTimeHex(String a, String b) {
    if (a.length != b.length) return false;
    return Cipher.constantTimeEquals(utf8.encode(a), utf8.encode(b));
  }

  /// Releases the node connection pool.
  void dispose() => _client.close();

  /// Chunk size used when splitting a file for the pool (matches the
  /// existing upload chunk size so transfer behaviour stays familiar).
  static int get chunkSize => AppConstants.uploadChunkSize;
}
