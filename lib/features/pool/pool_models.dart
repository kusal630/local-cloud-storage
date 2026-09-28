/// Dumb data models for the v2.4.0 Pooled Data Cloud UI.
///
/// These are the shapes the UI renders. The client service slice
/// (`lib/client/services/pool_service.dart`, built later) constructs them from
/// API responses and feeds them to `PoolScreen`. Keep this file free of Flutter
/// widgets, Dio, and any I/O — `fromJson` only.
///
/// Totals follow RESEARCH/CONSULT.md §4: a pool total is always *derived*
/// (`totalQuota` / `usedBytes` come pre-summed from the host), never
/// accumulated in the UI. Rows in `DEAD`/`REVOKED` states are excluded by the
/// host, which is how leave stops counting.
library;

/// Lifecycle of a single contributor, as reported by the host coordinator.
enum PoolContributorStatus {
  /// ALIVE — heartbeat fresh, counted in every pool total.
  online,

  /// Suspect/Dead/Left — kept out of placement; its quota is unavailable.
  offline,

  /// Pairing handshake in flight (register → token → first heartbeat).
  joining,

  /// Join attempt failed or timed out (>15s).
  failed,
}

/// One device contributing quota to the pool.
class PoolContributor {
  const PoolContributor({
    required this.id,
    required this.name,
    required this.quotaBytes,
    required this.usedBytes,
    this.status = PoolContributorStatus.online,
    this.isThisDevice = false,
    this.deviceKind = 'phone',
    this.lastSeen,
  });

  final String id;

  /// Human name shown in the list ("Pixel 7").
  final String name;

  /// This contributor's slice of the pool (`quota_bytes`).
  final int quotaBytes;

  /// Bytes this contributor currently stores (`used_bytes`).
  final int usedBytes;

  final PoolContributorStatus status;

  /// True for the device the app is running on — pinned to the top and
  /// labelled "This device".
  final bool isThisDevice;

  /// Coarse device class for the leading glyph: `phone` / `laptop` /
  /// `tablet` / `server`. Unknown values fall back to a phone icon.
  final String deviceKind;

  /// Last heartbeat from this contributor — shown as recency language
  /// ("last seen 12m ago"), never a raw timestamp (§10).
  final DateTime? lastSeen;

  /// Fraction of this contributor's own share that is used (0..1).
  double get usedFraction =>
      quotaBytes <= 0 ? 0.0 : (usedBytes / quotaBytes).clamp(0.0, 1.0);

  bool get isOnline => status == PoolContributorStatus.online;
  bool get isOffline => status == PoolContributorStatus.offline;
  bool get isJoining => status == PoolContributorStatus.joining;

  PoolContributor copyWith({
    String? name,
    int? quotaBytes,
    int? usedBytes,
    PoolContributorStatus? status,
    bool? isThisDevice,
    String? deviceKind,
    DateTime? lastSeen,
  }) {
    return PoolContributor(
      id: id,
      name: name ?? this.name,
      quotaBytes: quotaBytes ?? this.quotaBytes,
      usedBytes: usedBytes ?? this.usedBytes,
      status: status ?? this.status,
      isThisDevice: isThisDevice ?? this.isThisDevice,
      deviceKind: deviceKind ?? this.deviceKind,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }

  factory PoolContributor.fromJson(Map<String, dynamic> json) {
    return PoolContributor(
      id: json['id'] as String? ?? json['contributor_id'] as String? ?? '',
      name: json['name'] as String? ?? json['device_name'] as String? ?? 'Device',
      quotaBytes: (json['quota_bytes'] as num?)?.toInt() ?? 0,
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      status: poolContributorStatusFromJson(
          json['status'] as String? ?? 'online'),
      isThisDevice: json['is_this_device'] as bool? ?? false,
      deviceKind: json['device_kind'] as String? ?? 'phone',
      lastSeen: _parseDateTime(json['last_seen']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'quota_bytes': quotaBytes,
        'used_bytes': usedBytes,
        'status': status.name,
        'is_this_device': isThisDevice,
        'device_kind': deviceKind,
        'last_seen': lastSeen?.toIso8601String(),
      };
}

/// Accepts epoch milliseconds or an ISO-8601 string.
DateTime? _parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  if (value is String) return DateTime.tryParse(value);
  return null;
}

/// Tolerant status parsing — the host speaks uppercase states
/// (`ALIVE`/`DEAD`/`REVOKED`/`JOINING`), the UI slice speaks lowercase.
PoolContributorStatus poolContributorStatusFromJson(String raw) {
  switch (raw.toLowerCase()) {
    case 'alive':
    case 'online':
    case 'ok':
      return PoolContributorStatus.online;
    case 'joining':
    case 'pending':
    case 'registering':
      return PoolContributorStatus.joining;
    case 'failed':
    case 'error':
    case 'rejected':
      return PoolContributorStatus.failed;
    case 'offline':
    case 'suspect':
    case 'dead':
    case 'left':
    case 'revoked':
    default:
      return PoolContributorStatus.offline;
  }
}

/// One consistent snapshot of the whole pool (CONSULT.md §4: the host derives
/// these sums in a single transaction so the number and the ring can't
/// disagree; the UI only ever renders the last snapshot it received).
class PoolStatus {
  const PoolStatus({
    required this.totalQuota,
    required this.usedBytes,
    this.contributors = const [],
    this.quotaExceeded = false,
    this.hostAvailableQuota,
    this.hostFreeBytes,
    this.reservedBytes = 0,
    this.healthLabel,
    this.chunkCount = 0,
    this.degradedChunks = 0,
  });

  /// Sum of quota over contributors the host still counts (ALIVE/SUSPECT).
  final int totalQuota;

  /// Sum of `used_bytes` over the same rows.
  final int usedBytes;

  final List<PoolContributor> contributors;

  /// Server flag: the pool rejected a write because it is full (mirrors the
  /// `usedFraction >= 0.9` threshold used by the storage screen).
  final bool quotaExceeded;

  /// Host's own `available_quota` — consumed verbatim, never recomputed.
  ///
  /// Null only when talking to a host that predates the field, in which case
  /// [availableQuota] falls back to the arithmetic below.
  final int? hostAvailableQuota;

  /// Host's own `free_bytes`, which is the only figure that already knows
  /// about in-flight reservations.
  final int? hostFreeBytes;

  /// Quota reserved by writes that have not committed yet.
  final int reservedBytes;

  /// Host's headline word (`EMPTY` / `ONLINE` / `DEGRADED` / `AT RISK` /
  /// `OFFLINE`), passed through for [PoolHealthBanner].
  final String? healthLabel;

  /// Chunks recorded for the whole pool, and how many are below R.
  final int chunkCount;
  final int degradedChunks;

  /// First-run / nobody contributing yet.
  factory PoolStatus.empty() => const PoolStatus(totalQuota: 0, usedBytes: 0);

  factory PoolStatus.fromJson(Map<String, dynamic> json) {
    final rawList = json['contributors'];
    return PoolStatus(
      totalQuota: (json['total_quota'] as num?)?.toInt() ?? 0,
      usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
      contributors: [
        if (rawList is List)
          for (final e in rawList)
            if (e is Map<String, dynamic>) PoolContributor.fromJson(e),
      ],
      quotaExceeded: json['quota_exceeded'] as bool? ?? false,
      hostAvailableQuota: (json['available_quota'] as num?)?.toInt(),
      hostFreeBytes: (json['free_bytes'] as num?)?.toInt(),
      reservedBytes: (json['reserved_bytes'] as num?)?.toInt() ?? 0,
      healthLabel: json['health'] as String?,
      chunkCount: (json['chunk_count'] as num?)?.toInt() ?? 0,
      degradedChunks: (json['degraded_chunks'] as num?)?.toInt() ?? 0,
    );
  }

  int get contributorCount => contributors.length;

  bool get isEmpty => contributors.isEmpty;

  Iterable<PoolContributor> get online =>
      contributors.where((c) => c.status == PoolContributorStatus.online);
  Iterable<PoolContributor> get offline =>
      contributors.where((c) => c.status == PoolContributorStatus.offline);
  Iterable<PoolContributor> get joining =>
      contributors.where((c) => c.status == PoolContributorStatus.joining);

  int get offlineCount => offline.length;
  int get joiningCount => joining.length;

  /// Quota parked on offline devices — temporarily unavailable capacity.
  int get offlineQuota =>
      offline.fold<int>(0, (sum, c) => sum + c.quotaBytes);

  /// Capacity a user can actually write to right now.
  ///
  /// The host's figure wins whenever it is present. `total_quota` already
  /// excludes every device the host stopped counting, so subtracting an
  /// offline device's quota *again* here counts the same loss twice: two
  /// 10 GB devices alive plus one that left showed as 10 GB where the pool
  /// really holds 20 GB. The arithmetic below exists only for a host that
  /// does not send the field yet.
  int get availableQuota {
    final host = hostAvailableQuota;
    if (host != null) return host < 0 ? 0 : host;
    if (contributors.isEmpty) return 0;
    return (totalQuota - offlineQuota).clamp(0, 1 << 62);
  }

  /// Bytes not yet written. Reservations are neither free nor used, so only
  /// the host — which holds both numbers in one transaction — can answer
  /// this honestly.
  int get freeBytes {
    final host = hostFreeBytes;
    if (host != null) return host < 0 ? 0 : host;
    return (totalQuota - usedBytes).clamp(0, 1 << 62);
  }

  double get usedFraction =>
      totalQuota <= 0 ? 0.0 : (usedBytes / totalQuota).clamp(0.0, 1.0);

  bool get hasOffline => offlineCount > 0;
  bool get allOffline => contributors.isNotEmpty && offlineCount == contributors.length;
  bool get hasJoining => joiningCount > 0;

  /// Pool full: host rejected writes, or the classic >=90% threshold.
  bool get isFull =>
      quotaExceeded || (totalQuota > 0 && usedFraction >= 0.9);

  /// Which of the four §7 states the screen should render.
  PoolViewState get viewState {
    if (isEmpty) return PoolViewState.empty;
    if (isFull) return PoolViewState.quotaExceeded;
    if (hasJoining) return PoolViewState.joining;
    if (hasOffline) return PoolViewState.degraded;
    return PoolViewState.healthy;
  }

  PoolStatus copyWith({
    int? totalQuota,
    int? usedBytes,
    List<PoolContributor>? contributors,
    bool? quotaExceeded,
  }) {
    return PoolStatus(
      totalQuota: totalQuota ?? this.totalQuota,
      usedBytes: usedBytes ?? this.usedBytes,
      contributors: contributors ?? this.contributors,
      quotaExceeded: quotaExceeded ?? this.quotaExceeded,
      hostAvailableQuota: hostAvailableQuota,
      hostFreeBytes: hostFreeBytes,
      reservedBytes: reservedBytes,
      healthLabel: healthLabel,
      chunkCount: chunkCount,
      degradedChunks: degradedChunks,
    );
  }
}

/// The four screen states from RESEARCH/DESIGN.md §7 (plus the healthy
/// default), derived from a single `PoolStatus` snapshot.
enum PoolViewState {
  /// A. 0 contributors — dashed ring + "Contribute this device" CTA.
  empty,

  /// B. ≥1 contributor offline — banner + available-capacity centre number.
  degraded,

  /// C. pool full / write rejected — error card + halo on the ring.
  quotaExceeded,

  /// D. pairing in flight — progress pill, placeholder arc, staged text.
  joining,

  /// Everything healthy.
  healthy,
}
