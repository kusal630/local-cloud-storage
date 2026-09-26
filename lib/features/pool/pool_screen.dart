import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/haptics/haptic_feedback.dart';
import '../../widgets/common.dart';
import '../../widgets/pool_capacity_card.dart';
import '../../widgets/pool_donut.dart';
import 'pool_contributor_tile.dart';
import 'pool_models.dart';

/// Loader signature for the pool snapshot.
///
/// The client-service slice (later) supplies
/// `() => poolService.fetchStatus()`; until then the screen falls back to an
/// empty snapshot so the UI ships independently of the data layer.
typedef PoolStatusLoader = Future<PoolStatus> Function();

/// Pooled Data Cloud screen (RESEARCH/DESIGN.md §7) — all four states:
/// empty, degraded, quota-exceeded, joining — plus pull/button refresh and
/// first-paint skeletons. Reached from the Storage tab and rendered inside
/// the 5-tab NavigationBar shell.
class PoolScreen extends StatefulWidget {
  const PoolScreen({super.key, this.fetchStatus});

  final PoolStatusLoader? fetchStatus;

  @override
  State<PoolScreen> createState() => _PoolScreenState();
}

class _PoolScreenState extends State<PoolScreen> {
  PoolStatus? _status;
  bool _loading = false;
  String? _error;

  Timer? _joinTimer;
  bool _joinTimedOut = false;

  // State-entry guards: haptics/announcements fire once, never per rebuild.
  bool _wasFull = false;
  bool _wasDegraded = false;

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

    // §10: live-region announcement for state changes.
    if (s.hasOffline && !s.isEmpty && !_wasDegraded) {
      final n = s.offlineCount;
      SemanticsService.sendAnnouncement(
        View.of(context),
        'Pool degraded, $n ${n == 1 ? 'device' : 'devices'} offline',
        TextDirection.ltr,
      );
    }
    _wasDegraded = s.hasOffline && !s.isEmpty;
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
          if (s.hasOffline) _degradedBanner(s),
          PoolCapacityCard(status: s),
          if (!s.isEmpty) ...[
            const SizedBox(height: 16),
            PoolContributorsCard(
              key: _contributorsKey,
              contributors: s.contributors,
              joinTimedOut: _joinTimedOut,
              onRetryJoin: _retryJoin,
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
  Widget _degradedBanner(PoolStatus s) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final tint = s.allOffline
        ? (brightness == Brightness.dark
            ? poolStatusError
            : poolStatusErrorLight)
        : (brightness == Brightness.dark
            ? poolStatusDegraded
            : poolStatusDegradedLight);
    final line1 = s.allOffline
        ? 'All ${s.contributorCount} devices are offline'
        : '${s.offlineCount} of ${s.contributorCount} devices are offline';
    final line2 = s.allOffline
        ? 'Reads repair from replicas when a device returns.'
        : '${formatPoolSize(s.offlineQuota)} temporarily unavailable';

    return AnimatedSize(
      duration:
          _reduce ? Duration.zero : const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: -12, end: 0),
          duration:
              _reduce ? Duration.zero : const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          builder: (context, dy, child) =>
              Transform.translate(offset: Offset(0, dy), child: child),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.wifi_off_rounded, color: tint),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(line1,
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(
                          line2,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color:
                                        scheme.onSurfaceVariant,
                                  ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _scrollToContributors,
                    child: const Text('Review'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
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
