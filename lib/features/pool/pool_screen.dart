import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/haptics/haptic_feedback.dart';
import '../../core/utils/disk_space_compat.dart';
import '../../widgets/common.dart';
import '../../widgets/pool_capacity_card.dart';
import '../../widgets/pool_donut.dart';
import 'contribute_sheet.dart';
import 'pool_contributor_tile.dart';
import 'pool_health_banner.dart';
import 'pool_models.dart';

/// Loader signature for the pool snapshot.
///
/// The router supplies `poolService.fetchStatus`; until it does the screen
/// falls back to an empty snapshot, which keeps the widget testable without
/// a host.
typedef PoolStatusLoader = Future<PoolStatus> Function();

/// Pooled Data Cloud screen (RESEARCH/DESIGN.md §7) — all four states:
/// empty, degraded, quota-exceeded, joining — plus pull/button refresh and
/// first-paint skeletons. Reached from the Storage tab and rendered inside
/// the 5-tab NavigationBar shell.
class PoolScreen extends StatefulWidget {
  const PoolScreen({
    super.key,
    this.fetchStatus,
    this.onRevoke,
    this.onContribute,
    this.onStop,
    this.onAddDevice,
    this.onQuotaChanged,
    this.freeSpaceOnThisDevice,
  });

  final PoolStatusLoader? fetchStatus;

  /// Give the pool a copy of everything [contributor] holds. The host
  /// returns immediately and re-replicates in the background, so the screen
  /// only has to refresh.
  final Future<void> Function(PoolContributor contributor)? onRevoke;

  /// Add — or re-size — this device's share of the pool.
  final Future<void> Function(int quotaBytes)? onContribute;

  /// Take this device back out of the pool.
  final Future<void> Function()? onStop;

  /// Where "Add device" goes. Null hides nothing: the contributors card
  /// falls back to inline feedback rather than offering a dead button.
  final VoidCallback? onAddDevice;

  /// Re-size someone's share without stopping them.
  final Future<void> Function(PoolContributor contributor, int quotaBytes)?
      onQuotaChanged;

  /// Real free space on this device — the contribute slider's maximum.
  /// Supplied by the router (which knows where the node's bytes will land);
  /// when absent the screen probes the working directory itself. An unknown
  /// answer must block the sheet, never become a made-up maximum.
  final Future<int> Function()? freeSpaceOnThisDevice;

  @override
  State<PoolScreen> createState() => _PoolScreenState();
}

class _PoolScreenState extends State<PoolScreen> {
  PoolStatus? _status;
  bool _loading = false;
  String? _error;

  /// When the snapshot behind the numbers landed, and the freshness line
  /// rendered from it (UX_BENCHMARK §9).
  DateTime? _updatedAt;
  String? _freshnessLine;
  Timer? _freshnessTimer;

  Timer? _joinTimer;
  bool _joinTimedOut = false;

  // State-entry guard: the error haptic fires once per entry, never per
  // rebuild. State *speech* belongs to PoolHealthBanner, which announces the
  // health word and the exact sentence together.
  bool _wasFull = false;

  /// Membership and quota as of the last successful snapshot. Diffing it
  /// against the next one is what earns a join/leave/quota announcement — a
  /// rebuild, or a heartbeat that carries no transition, stays silent.
  Map<String, PoolContributor>? _knownContributors;
  int? _knownTotalQuota;

  bool _reduce = false;
  final _contributorsKey = GlobalKey();

  PoolStatusLoader get _loader =>
      widget.fetchStatus ?? (() async => PoolStatus.empty());

  @override
  void initState() {
    super.initState();
    _load();
    // The freshness line has to keep telling the truth while the screen sits
    // still, so it re-reads `formatRelative` on a slow tick and repaints only
    // when the words would actually change (a tick that changes nothing is
    // not worth a frame).
    _freshnessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final at = _updatedAt;
      if (at == null || !mounted) return;
      final next = 'Updated ${formatRelative(at)}';
      if (next == _freshnessLine) return;
      setState(() => _freshnessLine = next);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.of(context).disableAnimations;
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _joinTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final status = await _loader();
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
        _updatedAt = DateTime.now();
        _freshnessLine = 'Updated ${formatRelative(_updatedAt!)}';
      });
      _afterLoad(status);
    } catch (e) {
      if (!mounted) return;
      AppHaptics.error();
      // §10: never a raw exception. First paint gets a fix-and-retry
      // sentence; a refresh that failed keeps the last snapshot on screen
      // and says so inline instead of silently presenting it as current.
      setState(() {
        _error = _messageFor(e);
        _loading = false;
      });
    }
  }

  void _afterLoad(PoolStatus s) {
    _syncJoinTimer(s);

    // §7C: AppHaptics.error() once per state entry, never per rebuild.
    final becameFull = s.isFull && !_wasFull;
    if (becameFull) AppHaptics.error();
    _wasFull = s.isFull;

    // One announcement per snapshot, ordered by what changes the user's
    // options: a full pool first, then membership, then the quota itself.
    if (becameFull) {
      _announce(
        'The pool is full. Free space, or raise a quota, before uploads '
        'resume.',
      );
    } else {
      _syncMembership(s);
    }
  }

  /// Diffs this snapshot against the previous one and speaks the transition:
  /// joined, removed, or quota changed. The first paint speaks nothing —
  /// there was no earlier state to have changed from.
  void _syncMembership(PoolStatus s) {
    final before = _knownContributors;
    final quotaBefore = _knownTotalQuota;
    final current = {for (final c in s.contributors) c.id: c};
    _knownContributors = current;
    _knownTotalQuota = s.totalQuota;
    if (before == null) return;

    String? message;
    var celebrate = false;
    for (final c in s.contributors) {
      final was = before[c.id];
      // A join lands as a member that was not there before, or as a
      // placeholder arc that finished pairing. A placeholder appearing, or a
      // join that failed, is neither.
      final landed = !c.isJoining && c.status != PoolContributorStatus.failed;
      if (was == null) {
        if (!landed) continue;
        message = '${c.name} joined the pool';
        celebrate = true;
        break;
      }
      if (was.isJoining && landed) {
        message = '${c.name} joined the pool';
        celebrate = true;
        break;
      }
    }
    if (message == null) {
      for (final id in before.keys) {
        if (current.containsKey(id)) continue;
        message = '${before[id]!.name} was removed from the pool';
        break;
      }
    }
    if (message == null && quotaBefore != null && quotaBefore != s.totalQuota) {
      message = 'Pool quota changed to ${spellPoolSize(s.totalQuota)}';
    }

    // §8/§9: one success pattern per join, even under reduced motion where
    // the ring's celebration spark never runs.
    if (celebrate) AppHaptics.success();
    if (message != null) _announce(message);
  }

  /// Screen-reader speech for transitions only — `sendAnnouncement`, never
  /// the deprecated `SemanticsService.announce` (§10; the same call
  /// PoolHealthBanner makes).
  void _announce(String message) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(
      View.of(context),
      message,
      TextDirection.ltr,
    );
  }

  /// The pool's one headline word.
  ///
  /// The host's label wins whenever it sends one: it holds every figure in a
  /// single transaction and knows things this screen cannot see — a chunk
  /// down to one copy, a write the pool refused. The fallback below exists
  /// only for a host that predates the field.
  PoolHealth _health(PoolStatus s) {
    final label = s.healthLabel;
    if (label != null && label.isNotEmpty) return PoolHealth.fromName(label);
    if (s.isEmpty) return PoolHealth.empty;
    if (s.allOffline) return PoolHealth.offline;
    if (s.degradedChunks > 0) return PoolHealth.atRisk;
    if (s.hasOffline) return PoolHealth.degraded;
    return PoolHealth.online;
  }

  /// The banner speaks only when it has something to say.
  ///
  /// An all-green pool already reports through the capacity card's health
  /// pill, and an empty pool has its own copy inside that card (DESIGN §7A),
  /// so a headline in either case would just repeat it a second time.
  bool get _showBanner {
    final s = _status;
    if (s == null || s.isEmpty) return false;
    return _health(s) != PoolHealth.online;
  }

  /// §7D: a join that takes >15s collapses the tile to error + Retry.
  void _syncJoinTimer(PoolStatus s) {
    if (s.hasJoining && !_joinTimedOut && _joinTimer == null) {
      _joinTimer = Timer(const Duration(seconds: 15), () {
        if (!mounted) return;
        setState(() => _joinTimedOut = true);
      });
    } else if (!s.hasJoining && _joinTimer != null) {
      _joinTimer!.cancel();
      _joinTimer = null;
      if (_joinTimedOut) setState(() => _joinTimedOut = false);
    }
  }

  void _retryJoin() {
    _joinTimer?.cancel();
    _joinTimer = null;
    setState(() => _joinTimedOut = false);
    _load();
  }

  void _scrollToContributors() {
    AppHaptics.light();
    final ctx = _contributorsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: _reduce
          ? Duration.zero
          : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pooled cloud'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Refresh pool',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_status == null) {
      if (_error != null) return ErrorState(message: _error!, onRetry: _load);
      return _skeleton();
    }
    final s = _status!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (s.isFull) _quotaExceededCard(s),
          if (_showBanner) _healthBanner(s),
          PoolHeroScope(
            onShowDetails: _showHeroDetails,
            child: PoolCapacityCard(
              status: s,
              onContribute: _openContributeSheet,
            ),
          ),
          _freshnessRow(),
          if (!s.isEmpty) ...[
            const SizedBox(height: 16),
            PoolContributorsCard(
              key: _contributorsKey,
              contributors: s.contributors,
              joinTimedOut: _joinTimedOut,
              onRetryJoin: _retryJoin,
              onAddDevice: widget.onAddDevice,
              onQuotaChanged: widget.onQuotaChanged == null
                  ? null
                  : (c, q) => _refresh(() => widget.onQuotaChanged!(c, q)),
              onRevoke: widget.onRevoke == null
                  ? null
                  : (c) => _refresh(() => widget.onRevoke!(c)),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // §7C — freshness (UX_BENCHMARK §9): when this snapshot landed, and — when
  // a refresh failed — an honest note that the screen is showing the last
  // numbers it managed to read. The exception itself never reaches the UI.
  // -------------------------------------------------------------------------
  Widget _freshnessRow() {
    final updatedAt = _updatedAt;
    if (updatedAt == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall;
    final refreshFailed = _error != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 14,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                _freshnessLine ?? 'Updated ${formatRelative(updatedAt)}',
                style: style?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          if (refreshFailed) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(
                    Icons.sync_problem_rounded,
                    size: 14,
                    color: scheme.error,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    "Couldn't refresh — showing the last known numbers.",
                    style: style?.copyWith(color: scheme.error),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // §7C — quota exceeded: mirrors the `usedFraction >= 0.9` error card in
  // storage_screen.dart (errorContainer @0.7 + icon + fix + action).
  // -------------------------------------------------------------------------
  Widget _quotaExceededCard(PoolStatus s) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration:
          _reduce ? Duration.zero : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Card(
          color: scheme.errorContainer.withValues(alpha: 0.7),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline_rounded,
                        color: scheme.onErrorContainer),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "The pool is full. Free space, raise a contributor's quota, or add a device before uploads resume.",
                        style: TextStyle(color: scheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _scrollToContributors,
                  child: const Text('Manage space'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // §7B — degraded: banner above the donut; the ring + pill handle the rest.
  // -------------------------------------------------------------------------
  // -------------------------------------------------------------------------
  // §7B — headline state banner: one health word plus one sentence that names
  // exactly what is at stake, and a Review that jumps to the list.
  // -------------------------------------------------------------------------
  Widget _healthBanner(PoolStatus s) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: PoolHealthBanner(
          health: _health(s),
          pooledBytes: s.usedBytes,
          totalDevices: s.contributorCount,
          offlineDevices: s.offlineCount,
          offlineBytes: s.offlineQuota,
          atRiskFiles: s.degradedChunks,
          onReview: _scrollToContributors,
        ),
      );

  // -------------------------------------------------------------------------
  // Actions. Every affordance on this screen either performs the real
  // operation or is left off entirely — there is no button here that quietly
  // does nothing.
  // -------------------------------------------------------------------------

  /// Runs [action] and reloads so the screen shows what the host actually
  /// did. Failures the caller cannot handle are surfaced by name; failures
  /// raised inside the contribute sheet are left for the sheet, which has a
  /// fix-and-Retry message of its own and would otherwise be buried by a
  /// snackbar.
  Future<void> _refresh(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        AppHaptics.error();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_messageFor(e))));
      }
      // Reconcile first, then hand the failure on: the caller has to learn
      // that the write never landed, or it will announce a success the pool
      // never accepted.
      if (mounted) await _load();
      rethrow;
    }
    if (mounted) await _load();
  }

  static String _messageFor(Object e) => e is AppException
      ? e.message
      : 'That did not work. Check that the pool host is reachable and try again.';

  Future<int> _freeSpaceOnThisDevice() async {
    final probe = widget.freeSpaceOnThisDevice;
    if (probe != null) return probe();
    // No caller-supplied probe: read the real disk. The slider must never
    // offer space this device does not have, so "unknown" has to read as 0 —
    // a number that blocks the sheet — rather than as a guess.
    final space = await DiskSpaceCompat.getSpace(Directory.current.path);
    return space?.free ?? 0;
  }

  /// Opens the single-decision contribute sheet (DESIGN §6).
  Future<void> _openContributeSheet() async {
    final s = _status;
    if (s == null) return;
    AppHaptics.light();

    if (widget.onContribute == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pool service not connected yet.')),
      );
      return;
    }

    final free = await _freeSpaceOnThisDevice();
    if (!mounted) return;
    if (free <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "This device's free space could not be read, so there is "
            'nothing it can offer the pool.',
          ),
        ),
      );
      return;
    }

    final index = s.contributors.indexWhere((c) => c.isThisDevice);
    final me = index < 0 ? null : s.contributors[index];

    await showContributeSheet(
      context,
      args: ContributeSheetArgs(
        currentPoolBytes: s.usedBytes,
        thisDeviceFreeBytes: free,
        isContributing: me != null,
        thisDeviceQuotaBytes: me?.quotaBytes ?? 0,
        thisDeviceUsedBytes: me?.usedBytes,
        thisDeviceSlotIndex: index < 0 ? null : index,
        // Thrown errors are the sheet's to render — it owns the retry copy.
        onContribute: (quota) async {
          await widget.onContribute!(quota);
          if (mounted) await _load();
        },
        onStop: () async {
          final stop = widget.onStop;
          if (stop == null) return;
          await stop();
          if (mounted) await _load();
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // §5 — the hero number, explained (UX_BENCHMARK §5): the breakdown sheet a
  // tap on the hero number opens. It lists every component of the total this
  // snapshot can actually answer; trash and replica overhead are not reported
  // by the pool state, so those rows are left out rather than guessed.
  // -------------------------------------------------------------------------

  /// `PoolDonut` looks this up through [PoolHeroScope], so the number and its
  /// explanation always come from the same snapshot (DESIGN §6: radius 24).
  void _showHeroDetails() {
    final s = _status;
    if (s == null) return;
    AppHaptics.light();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      // Spelled out (rather than relying on `bottomSheetTheme`) so the sheet
      // keeps the DESIGN.md §6 radius 24 geometry wherever it is shown.
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final text = Theme.of(sheetContext).textTheme;
        final scheme = Theme.of(sheetContext).colorScheme;
        final offlineSubtracted = s.hasOffline && !s.allOffline;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
            ),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Where this number comes from',
                      style: text.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.isEmpty
                          ? 'No devices are contributing yet, so the pool has '
                              'no quota to break down.'
                          : "Each device's share of its free space, added "
                              "together — that is the pool's quota.",
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 16),
                    for (final c in s.contributors)
                      _detailRow(
                        sheetContext,
                        _contributorLabel(c),
                        c.quotaBytes,
                      ),
                    if (s.contributors.isNotEmpty) ...[
                      const Divider(height: 24),
                      _detailRow(
                        sheetContext,
                        'Pool quota',
                        s.totalQuota,
                        emphasised: true,
                      ),
                      if (offlineSubtracted) ...[
                        _detailRow(
                          sheetContext,
                          'Offline right now',
                          s.offlineQuota,
                          note: 'Subtracted from the number while those '
                              'devices are unreachable.',
                        ),
                        _detailRow(
                          sheetContext,
                          'Available now',
                          s.availableQuota,
                          emphasised: true,
                        ),
                      ],
                      if (s.reservedBytes > 0)
                        _detailRow(
                          sheetContext,
                          'Reserved for uploads',
                          s.reservedBytes,
                          note: 'Claimed by an upload that has not finished '
                              'yet. It becomes used when the write commits, '
                              'or free again if it fails.',
                        ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: const Text('Close'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Legend-style row label: the device name, plus the state word whenever it
  /// explains why that share is not in play — never a hue on its own (§10).
  static String _contributorLabel(PoolContributor c) => switch (c.status) {
        PoolContributorStatus.online => c.name,
        PoolContributorStatus.offline => '${c.name} (offline)',
        PoolContributorStatus.joining => '${c.name} (joining)',
        PoolContributorStatus.failed => '${c.name} (join failed)',
      };

  /// One "what — how much" row: label left, `formatBytes` figure right, and
  /// an optional plain-language note underneath. The spoken figure spells its
  /// unit out (§10) while the visible copy stays `30.0 GB`.
  Widget _detailRow(
    BuildContext sheetContext,
    String label,
    int bytes, {
    bool emphasised = false,
    String? note,
  }) {
    final text = Theme.of(sheetContext).textTheme;
    final scheme = Theme.of(sheetContext).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: text.bodyMedium?.copyWith(
                    fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                formatBytes(bytes),
                semanticsLabel: spellPoolSize(bytes),
                style: poolMonoDigits.copyWith(
                  fontSize: 14,
                  fontWeight: emphasised ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: 2),
            Text(
              note,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }

  // First paint — same shimmer skeleton language as SkeletonList.
  // -------------------------------------------------------------------------
  Widget _skeleton() {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget box(double height, double radius) {
      final w = Container(
        height: height,
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(radius),
        ),
      );
      if (_reduce) return w;
      return w
          .animate(onPlay: (controller) => controller.repeat())
          .shimmer(
            duration: const Duration(milliseconds: 1400),
            color: c.withValues(alpha: 0.9),
          );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        box(340, 20),
        const SizedBox(height: 16),
        box(96, 16),
        const SizedBox(height: 8),
        box(96, 16),
        const SizedBox(height: 8),
        box(96, 16),
      ],
    );
  }
}
