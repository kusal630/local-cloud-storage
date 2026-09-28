import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/haptics/haptic_feedback.dart';
import '../../core/utils/disk_space_compat.dart';
import '../../widgets/common.dart';
import '../../widgets/pool_capacity_card.dart';
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

  Timer? _joinTimer;
  bool _joinTimedOut = false;

  // State-entry guard: the error haptic fires once per entry, never per
  // rebuild. State *speech* belongs to PoolHealthBanner, which announces the
  // health word and the exact sentence together.
  bool _wasFull = false;

  bool _reduce = false;
  final _contributorsKey = GlobalKey();

  PoolStatusLoader get _loader =>
      widget.fetchStatus ?? (() async => PoolStatus.empty());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.of(context).disableAnimations;
  }

  @override
  void dispose() {
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
      });
      _afterLoad(status);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _afterLoad(PoolStatus s) {
    _syncJoinTimer(s);

    // §7C: AppHaptics.error() once per state entry, never per rebuild.
    if (s.isFull && !_wasFull) AppHaptics.error();
    _wasFull = s.isFull;

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
          PoolCapacityCard(
            status: s,
            onContribute: _openContributeSheet,
          ),
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
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_messageFor(e))));
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
