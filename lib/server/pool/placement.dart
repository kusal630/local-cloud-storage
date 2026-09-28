/// Weighted rendezvous hashing (HRW) placement for the v2.4.0 pooled cloud.
///
/// Spec: `RESEARCH/CONSULT.md` §3 — placement must be *derivable* (anyone can
/// recompute where a chunk should live from `chunkId` + the live contributor
/// set) **and** *diverse* (two copies of one chunk must never land on the same
/// physical device, which is the Tahoe-LAFS "servers of happiness" trap:
/// count-only health passes files whose copies all sit on one or two peers).
///
/// The weighted-rendezvous transform used here is the classic one:
///
/// ```text
/// u        = hash64(chunkId | contributorId) normalised into (0, 1]
/// score    = -weight / ln(u)
/// ```
///
/// Because `ln(u) < 0`, larger weights win more often, but *every* chunk gets
/// a stable, deterministic ranking — so a reader can recompute the ideal
/// placement after a membership change without any coordination, while a
/// previously placed chunk keeps its current copies (no reshuffle on join;
/// ZFS/Unraid never restripe either).
library;

import 'dart:math';

/// One placement input: a contributor that is eligible to hold chunks.
class PlacementCandidate {
  const PlacementCandidate({
    required this.id,
    required this.freeBytes,
    required this.quotaBytes,
    this.usedBytes = 0,
  });

  /// Contributor id (`contributors.id`).
  final String id;

  /// Last heartbeat-reported free space — weighting only, never admission
  /// (CONSULT §6 control 3: the ledger, not a claim, admits writes).
  final int freeBytes;

  /// Hard quota cap this contributor offers the pool.
  final int quotaBytes;

  /// Bytes already accounted on this contributor.
  final int usedBytes;

  /// Free space inside this contributor's own cap.
  int get capHeadroom {
    final headroom = quotaBytes - usedBytes;
    return headroom < 0 ? 0 : headroom;
  }

  /// HRW weight: `clamp(floor(free / 64 MiB), 1, 64)` (CONSULT §3) — capped
  /// so a 1 TB device cannot dominate the pool and the virtual-node loop
  /// stays bounded. Taken as the *smaller* of the raw-disk and cap-headroom
  /// weights, so a nearly-full 1 TB contributor stops winning placements
  /// before it reports a smaller `free_bytes`.
  int get weight {
    const unit = 64 * 1024 * 1024;
    final byFree = _clamp(freeBytes ~/ unit, 1, 64);
    final byCap = _clamp(capHeadroom ~/ unit, 1, 64);
    return min(byFree, byCap);
  }

  static int _clamp(int value, int low, int high) =>
      value < low ? low : (value > high ? high : value);
}

/// Deterministic 64-bit hash over [value]: FNV-1a + the MurmurHash3 finalizer.
///
/// Two deliberate choices:
/// * **not** `String.hashCode` — that is seeded per isolate and would make
///   placement differ between the coordinator and any reader recomputing it;
/// * **not plain FNV-1a** — its product is `L * (2^40 + 435)`, so the *top*
///   bits of the digest are literally the *low* bits of the input. Our keys
///   differ only in their last bytes (the contributor-id suffix), so plain
///   FNV-1a put devices in a fixed order (measured: 1249/1877/1874/2500/2500
///   placements where 2000 each was expected). `fmix64` mixes across all 64
///   bits and restores a uniform spread.
///
/// Dart VM integers wrap on overflow, which is exactly the mod-2^64
/// arithmetic FNV/murmur require.
int fnv1a64(String value) {
  const mask = 0xFFFFFFFFFFFFFFFF;
  var hash = 0xcbf29ce484222325;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) & mask;
    hash = (hash * 0x100000001b3) & mask;
  }
  // MurmurHash3 fmix64 finalizer.
  hash ^= hash >>> 33;
  hash = (hash * 0xff51afd7ed558ccd) & mask;
  hash ^= hash >>> 33;
  hash = (hash * 0xc4ceb9fe1a85ec53) & mask;
  hash ^= hash >>> 33;
  return hash & mask;
}

/// Rendezvous score of [chunkId] on one candidate — higher wins.
double rendezvousScore(String chunkId, PlacementCandidate candidate) {
  final hash = fnv1a64('$chunkId|${candidate.id}');
  // Fold to a uniform double in (0, 1]: the top 53 bits of a good hash are
  // uniformly distributed, and `>>> 11` is the standard 64 -> 53 bit fold.
  var u = ((hash >>> 11) & 0x1FFFFFFFFFFFFF) / 9007199254740992.0;
  if (u <= 0) u = 1 / 9007199254740992; // never log(0)
  return -candidate.weight / log(u);
}

/// Placement decisions for one chunk.
class ChunkPlacement {
  const ChunkPlacement({required this.chunkId, required this.contributorIds});

  final String chunkId;

  /// Ordered by preference: index 0 is the primary copy.
  final List<String> contributorIds;

  int get replicaCount => contributorIds.length;
}

abstract class PoolPlacement {
  PoolPlacement._();

  /// Replication factor for a household-sized pool (FEATURES §3: `R=2`
  /// replication beats erasure coding on explainability for 2–5 devices).
  static const int defaultReplication = 2;

  /// Ideal home for [chunkId] among [candidates]: the top [replication]
  /// distinct contributors by weighted rendezvous score. Never returns the
  /// same contributor twice (diversity rule), and returns fewer entries when
  /// fewer than [replication] candidates are eligible — the caller marks the
  /// chunk `UNDER_REPLICATED` rather than placing two copies on one device.
  static ChunkPlacement place(
    String chunkId,
    List<PlacementCandidate> candidates, {
    int replication = defaultReplication,
  }) {
    if (candidates.isEmpty || replication <= 0) {
      return ChunkPlacement(chunkId: chunkId, contributorIds: const []);
    }
    final ranked = [...candidates]
      ..sort((a, b) =>
          rendezvousScore(chunkId, b).compareTo(rendezvousScore(chunkId, a)));
    final picked = <String>[];
    for (final candidate in ranked) {
      if (picked.length >= replication) break;
      if (picked.contains(candidate.id)) continue;
      picked.add(candidate.id);
    }
    return ChunkPlacement(chunkId: chunkId, contributorIds: picked);
  }

  /// Ranks every candidate for [chunkId] — used by the repair worker to find
  /// the *next* best home when the primary copy's device died.
  static List<String> rankedIds(
    String chunkId,
    List<PlacementCandidate> candidates,
  ) {
    final ranked = [...candidates]
      ..sort((a, b) =>
          rendezvousScore(chunkId, b).compareTo(rendezvousScore(chunkId, a)));
    return ranked.map((c) => c.id).toList();
  }

  /// Tahoe-LAFS "servers of happiness", adapted to replication: how many
  /// *device failures* the given layout survives?
  ///
  /// A set [F] of failed devices keeps every chunk readable only while no
  /// chunk's whole replica set sits inside [F], so the answer is
  /// `min over chunks of (distinct replica devices) - 1`. A layout built for
  /// `R=2` on three devices therefore survives any single device dying —
  /// the guarantee the pool screen has to be honest about.
  static int maxSurvivableFailures(
    Map<String, List<String>> replicasByChunk,
  ) {
    if (replicasByChunk.isEmpty) return 0;
    var worst = 1 << 30;
    for (final ids in replicasByChunk.values) {
      final distinct = ids.toSet().length;
      if (distinct < worst) worst = distinct;
    }
    return worst <= 0 ? 0 : worst - 1;
  }

  /// Fraction of chunks holding at least [target] distinct replica devices —
  /// the health number behind the pool headline (0.0 … 1.0).
  static double happiness(
    Map<String, List<String>> replicasByChunk, {
    int target = defaultReplication,
  }) {
    if (replicasByChunk.isEmpty) return 1.0;
    var healthy = 0;
    for (final ids in replicasByChunk.values) {
      if (ids.toSet().length >= target) healthy++;
    }
    return healthy / replicasByChunk.length;
  }

  /// True when no chunk has both copies on one device — the diversity
  /// invariant, asserted directly by tests.
  static bool isDiverse(Map<String, List<String>> replicasByChunk) {
    for (final ids in replicasByChunk.values) {
      if (ids.toSet().length != ids.length) return false;
    }
    return true;
  }
}
