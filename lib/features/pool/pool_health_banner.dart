import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../widgets/common.dart';
import '../../widgets/pool_donut.dart';

/// Headline pool state — the single coloured word above everything, in the
/// ZFS `ONLINE` / `DEGRADED` / `AT RISK` vocabulary of
/// RESEARCH/FEATURES.md §169.
///
/// The UI mirror of the coordinator's `health` field: the client parses the
/// API's `health.name` string into this enum with [PoolHealth.fromName],
/// so `lib/features/pool` never has to import the server graph.
enum PoolHealth {
  /// Nobody contributing yet.
  empty('EMPTY'),

  /// Every contributor is counted and reachable.
  online('ONLINE'),

  /// ≥1 contributor offline, but reads still repair from replicas.
  degraded('DEGRADED'),

  /// No redundancy left: one copy of at least one chunk.
  atRisk('AT RISK'),

  /// Every contributor offline — the pool cannot be read or written.
  offline('OFFLINE');

  const PoolHealth(this.label);

  /// Exact word rendered in the banner (test-readable, meaning is never
  /// carried by hue alone).
  final String label;

  /// Tolerant parse of the host's `health` name (`atRisk`, `AT_RISK`, …).
  static PoolHealth fromName(String raw) {
    final normalised = raw.trim().replaceAll(' ', '').toLowerCase();
    return switch (normalised) {
      'online' || 'ok' || 'healthy' => PoolHealth.online,
      'degraded' => PoolHealth.degraded,
      'atrisk' || 'at_risk' || 'risk' => PoolHealth.atRisk,
      'offline' || 'down' => PoolHealth.offline,
      _ => PoolHealth.empty,
    };
  }
}

/// ZFS-style headline state banner (RESEARCH/FEATURES.md §169,
/// RESEARCH/DESIGN.md §7B): one health word + one plain sentence, an optional
/// inline resilver-style repair row, and a live announcement on every state
/// change.
///
/// Psychology:
/// * **Loss aversion** — a degraded pool never looks healthy: the word flips
///   to `DEGRADED`/`AT RISK`, the copy names exactly what is at stake
///   ("11 GB temporarily unavailable", "no redundancy: 1 copy of 14 files")
///   and the sub-line goes amber/red, not just the dot.
/// * **Peak–end / recency** — the row carries a determinate percentage, so a
///   screen-reader user ends on "…% done" instead of an indefinite spinner.
/// * **Aesthetic–usability** — one card, one sentence, one number; calm
///   default view (2026 dashboard trend).
///
/// Motion: `AnimatedSize` 240ms `easeOutCubic` + a 12px slide-down on state
/// entry (§8). Under `MediaQuery.disableAnimations` neither wrapper is built,
/// so the banner paints at its resting position with no running controller.
class PoolHealthBanner extends StatefulWidget {
  const PoolHealthBanner({
    super.key,
    required this.health,
    this.pooledBytes = 0,
    this.totalDevices = 0,
    this.offlineDevices = 0,
    this.offlineBytes = 0,
    this.atRiskFiles = 0,
    this.repairDone = 0,
    this.repairTotal = 0,
    this.repairEta,
    this.onReview,
  });

  final PoolHealth health;

  /// Pooled capacity shown while [health] is [PoolHealth.online].
  final int pooledBytes;

  /// How many contributors the host counts (denominator of "2 of 3").
  final int totalDevices;

  /// How many of [totalDevices] are offline (DEGRADED only).
  final int offlineDevices;

  /// Quota parked on those offline devices — the figure that is *at risk*.
  final int offlineBytes;

  /// Chunks holding a single copy (AT RISK only).
  final int atRiskFiles;

  /// Resilver row: replicas rebuilt so far, and how many remain in total.
  /// The row renders whenever [repairTotal] > 0.
  final int repairDone;
  final int repairTotal;

  /// Estimated time left for the repair pass, if the host provided one.
  final Duration? repairEta;

  /// Optional `Review` action for the unhealthy states (§7B).
  final VoidCallback? onReview;

  @override
  State<PoolHealthBanner> createState() => _PoolHealthBannerState();
}

class _PoolHealthBannerState extends State<PoolHealthBanner> {
  /// Announce once per *state entry*, never per rebuild (§10): the first
  /// paint speaks only when something is already wrong, and every later
  /// change speaks once.
  bool _firstPass = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_firstPass) {
      _firstPass = false;
      if (widget.health != PoolHealth.online) _announce();
    }
  }

  @override
  void didUpdateWidget(covariant PoolHealthBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.health != widget.health) _announce();
  }

  void _announce() {
    SemanticsService.sendAnnouncement(
      View.of(context),
      _announcement,
      TextDirection.ltr,
    );
  }

  String get _announcement {
    final sub = _subtitle;
    return sub == null
        ? '${widget.health.label}. $_title'
        : '${widget.health.label}. $_title. $sub';
  }

  String get _title => switch (widget.health) {
    PoolHealth.empty => 'No devices contributing yet',
    PoolHealth.online =>
      '${widget.totalDevices} ${widget.totalDevices == 1 ? 'device is' : 'devices are'} online',
    PoolHealth.degraded =>
      '${widget.offlineDevices} of ${widget.totalDevices} devices are offline',
    PoolHealth.atRisk =>
      'No redundancy: 1 copy of ${widget.atRiskFiles} ${widget.atRiskFiles == 1 ? 'file' : 'files'}',
    PoolHealth.offline => 'All ${widget.totalDevices} devices are offline',
  };

  String? get _subtitle => switch (widget.health) {
    PoolHealth.empty =>
      'Contribute free space from this device to start your pool.',
    PoolHealth.online => '${formatPoolSize(widget.pooledBytes)} pooled',
    // Loss aversion: name the bytes that are *at risk*, not a hue.
    PoolHealth.degraded =>
      '${formatPoolSize(widget.offlineBytes)} temporarily unavailable',
    PoolHealth.atRisk => 'Reconnect a device to re-replicate second copies.',
    PoolHealth.offline =>
      'Nothing can be read or written until a device reconnects.',
  };

  ({IconData icon, Color color}) _tone(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return switch (widget.health) {
      PoolHealth.empty => (
        icon: Icons.cloud_queue_rounded,
        color: dark ? poolStatusOffline : poolStatusOfflineLight,
      ),
      PoolHealth.online => (
        icon: Icons.check_circle_outline_rounded,
        color: dark ? poolStatusOnline : poolStatusOnlineLight,
      ),
      PoolHealth.degraded => (
        icon: Icons.wifi_off_rounded,
        color: dark ? poolStatusDegraded : poolStatusDegradedLight,
      ),
      PoolHealth.atRisk => (
        icon: Icons.warning_amber_rounded,
        color: dark ? poolStatusError : poolStatusErrorLight,
      ),
      PoolHealth.offline => (
        icon: Icons.cloud_off_rounded,
        color: dark ? poolStatusError : poolStatusErrorLight,
      ),
    };
  }

  /// Amber/red sub-lines only where the token clears 4.5:1 (§3).
  Color _subtitleColor(BuildContext context, Color tone) {
    final scheme = Theme.of(context).colorScheme;
    return switch (widget.health) {
      PoolHealth.degraded || PoolHealth.atRisk || PoolHealth.offline => tone,
      _ => scheme.onSurfaceVariant,
    };
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    final tone = _tone(context);
    final sub = _subtitle;

    // §8: `AnimatedSize` 240ms `easeOutCubic` + a 12px slide-down on state
    // entry. Under reduced motion neither animation widget is built at all:
    // a zero-duration `AnimatedSize` still creates a controller that
    // completes synchronously mid-layout and re-dirties its render box, so
    // we jump straight to the resting position instead.
    final content = Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(tone.icon, size: 24, color: tone.color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.health.label,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.2,
                                color: tone.color,
                              ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _title,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (sub != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: _subtitleColor(context, tone.color),
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.onReview != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 44),
                      ),
                      onPressed: widget.onReview,
                      child: const Text('Review'),
                    ),
                ],
              ),
              if (widget.repairTotal > 0) ...[
                const SizedBox(height: 16),
                _repairRow(context, tone.color),
              ],
            ],
          ),
        ),
      ),
    );

    if (reduce) return content;
    const duration = Duration(milliseconds: 240);
    return AnimatedSize(
      duration: duration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      // A keyed tween re-runs the 12px slide-down on every state entry.
      child: TweenAnimationBuilder<double>(
        key: ValueKey<PoolHealth>(widget.health),
        tween: Tween<double>(begin: -12, end: 0),
        duration: duration,
        curve: Curves.easeOutCubic,
        builder: (context, dy, child) =>
            Transform.translate(offset: Offset(0, dy), child: child),
        child: content,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Resilver row (RESEARCH/FEATURES.md §236): determinate bar + count + ETA,
  // never an indeterminate spinner — a repair must *look* like it progresses.
  // -------------------------------------------------------------------------
  Widget _repairRow(BuildContext context, Color tone) {
    final scheme = Theme.of(context).colorScheme;
    final total = widget.repairTotal;
    final done = widget.repairDone < 0
        ? 0
        : (widget.repairDone > total ? total : widget.repairDone);
    final value = total == 0 ? 0.0 : done / total;
    final finished = done >= total;
    final eta = widget.repairEta;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.sync_rounded, size: 16, color: tone),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                finished
                    ? 'Repair complete — $total of $total replicas verified'
                    : 'Repairing $done of $total replicas…',
                key: const ValueKey<String>('repairLine'),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        if (!finished && eta != null) ...[
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: Text(
              'about ${formatDuration(eta)} left',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              key: const ValueKey<String>('repairProgress'),
              value: value,
              minHeight: 6,
              color: tone,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 24),
          // The percentage keeps the meaning readable in greyscale — a bar
          // alone would encode progress by colour/length only (§10).
          child: Text(
            '${(value * 100).round()}% of replicas rebuilt',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
