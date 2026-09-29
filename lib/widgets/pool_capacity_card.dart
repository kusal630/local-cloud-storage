import 'package:flutter/material.dart';

import '../core/haptics/haptic_feedback.dart';
import '../features/pool/pool_models.dart';
import 'common.dart';
import 'glassmorphism.dart';
import 'pool_donut.dart';

// ---------------------------------------------------------------------------
// Graded capacity thresholds — RESEARCH/UX_BENCHMARK.md item 2, applied to
// the pool hero exactly as the storage screen applies them to its donut:
// 75% warms the number, 85% warms the ring and adds a sentence, 90% keeps
// the full treatment this card already had.
// ---------------------------------------------------------------------------

enum _CapacityLevel { ok, watch, warn, full }

_CapacityLevel _levelOf(PoolStatus s) {
  if (s.isFull) return _CapacityLevel.full;
  final f = s.usedFraction;
  if (f >= 0.85) return _CapacityLevel.warn;
  if (f >= 0.75) return _CapacityLevel.watch;
  return _CapacityLevel.ok;
}

/// Words for the warning bands (DESIGN §10: hue never carries the meaning
/// alone). The `watch` band states the number; only `warn` gets the
/// warning glyph, so 75% reads as a note and 85% as an alarm.
class _CapacityNote extends StatelessWidget {
  const _CapacityNote({required this.level, required this.fraction});

  final _CapacityLevel level;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tone = dark ? poolStatusDegraded : poolStatusDegradedLight;
    final isWarn = level == _CapacityLevel.warn;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          if (isWarn) ...[
            Icon(Icons.warning_amber_rounded, size: 16, color: tone),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              isWarn
                  ? 'Almost full — free up space soon.'
                  : 'The pool is ${(fraction * 100).round()}% full.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: tone,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Hero "one number, many contributors" card (RESEARCH/DESIGN.md §5).
///
/// GlassCard radius 20, top padding 24 (the page anchor). On AMOLED it fills
/// with `surfaceContainer @0.72` instead of a blur-heavy tint so the ring
/// stays crisp over pure black.
class PoolCapacityCard extends StatefulWidget {
  const PoolCapacityCard({
    super.key,
    required this.status,
    this.onContribute,
    this.onHowPoolingWorks,
    this.onReview,
    this.onManageSpace,
  });

  final PoolStatus status;

  /// Optional overrides — with none supplied the card falls back to honest
  /// inline feedback until the pool service slice wires the real actions.
  final VoidCallback? onContribute;
  final VoidCallback? onHowPoolingWorks;
  final VoidCallback? onReview;
  final VoidCallback? onManageSpace;

  @override
  State<PoolCapacityCard> createState() => _PoolCapacityCardState();
}

class _PoolCapacityCardState extends State<PoolCapacityCard> {
  int? _focused; // legend-chip focus (§8: 16→20 stroke, others 0.45 alpha)

  void _focus(int index) {
    AppHaptics.selection();
    setState(() => _focused = _focused == index ? null : index);
  }

  ({String label, Color color}) _health(PoolStatus s) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Color online = dark ? poolStatusOnline : poolStatusOnlineLight;
    Color off = dark ? poolStatusOffline : poolStatusOfflineLight;
    Color joining = dark ? poolStatusJoining : poolStatusJoiningLight;
    Color degraded = dark ? poolStatusDegraded : poolStatusDegradedLight;
    Color error = dark ? poolStatusError : poolStatusErrorLight;
    if (s.isEmpty) return (label: 'Empty', color: off);
    if (s.isFull) return (label: 'Full', color: error);
    if (s.hasJoining) return (label: 'Joining', color: joining);
    if (s.allOffline) return (label: 'Offline', color: error);
    if (s.hasOffline) return (label: 'Degraded', color: degraded);
    return (label: 'Healthy', color: online);
  }

  int _centerBytes(PoolStatus s) {
    if (s.isEmpty) return 0;
    // Degraded centres on the number that changes what the user does (§7B);
    // an all-offline pool keeps the total and lets the banner explain.
    if (s.hasOffline && !s.allOffline) return s.availableQuota;
    return s.totalQuota;
  }

  String _subLine(PoolStatus s) {
    if (s.isEmpty) return '0 GB free';
    if (s.hasOffline && !s.allOffline) {
      return '${formatPoolSize(s.offlineQuota)} offline';
    }
    final parts = <String>[
      if (s.usedBytes > 0) '${formatPoolSize(s.usedBytes)} used',
      '${formatPoolSize(s.freeBytes)} free',
    ];
    return parts.join(' · ');
  }

  /// ≥85%: an outline *around* the ring — amber, red once the pool is full.
  ///
  /// The segments keep their per-device colours (a pool ring has to stay
  /// legible as a set of contributors), so the graded signal is a second,
  /// outer ring rather than a repaint: a shape cue as well as a hue, with
  /// the sentence under the donut carrying the meaning in words (§10).
  /// Below 85% nothing is added, so the healthy card is untouched.
  Widget _gradedRing(
    Widget child, {
    required _CapacityLevel level,
    required Color amber,
    required Color errorColor,
  }) {
    if (level != _CapacityLevel.warn && level != _CapacityLevel.full) {
      return child;
    }
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: level == _CapacityLevel.warn ? amber : errorColor,
          width: 2,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final isAmoled = scheme.surface == const Color(0xFF000000);
    final s = widget.status;
    final health = _health(s);
    final errorColor =
        brightness == Brightness.dark ? poolStatusError : poolStatusErrorLight;
    final amber = brightness == Brightness.dark
        ? poolStatusDegraded
        : poolStatusDegradedLight;
    // Graded thresholds (item 2): the centre number warms at 75%, the ring
    // and a sentence join at 85%, and `isFull` keeps the red centre + halo
    // this card has always had.
    final level = _levelOf(s);
    final centerColor = switch (level) {
      _CapacityLevel.full => errorColor,
      _CapacityLevel.watch || _CapacityLevel.warn => amber,
      _CapacityLevel.ok => null,
    };

    final segments = <PoolDonutSegment>[
      for (var i = 0; i < s.contributors.length; i++)
        PoolDonutSegment(
          quota: s.contributors[i].quotaBytes,
          used: s.contributors[i].usedBytes,
          color: poolSegmentAt(i, brightness),
          isOffline: s.contributors[i].isOffline,
          isJoining: s.contributors[i].isJoining,
        ),
    ];

    return GlassCard(
      borderRadius: 20,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      blur: isAmoled ? 0 : 20,
      opacity: isAmoled ? 0.72 : 0.15,
      borderColor: scheme.outlineVariant.withValues(alpha: 0.2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            title: 'POOLED CLOUD',
            action: StatusPill(label: health.label, color: health.color),
          ),
          const SizedBox(height: 8),
          Center(
            child: _gradedRing(
              PoolDonut(
                segments: segments,
                centerBytes: _centerBytes(s),
                centerSubLine: _subLine(s),
                centerColor: centerColor,
                totalQuota: s.totalQuota,
                halo: s.isFull,
                focusedIndex: _focused,
                dashed: s.isEmpty,
              ),
              level: level,
              amber: amber,
              errorColor: errorColor,
            ),
          ),
          if (level == _CapacityLevel.watch || level == _CapacityLevel.warn)
            _CapacityNote(level: level, fraction: s.usedFraction),
          const SizedBox(height: 20),
          _PoolStats(
            contributors: s.contributorCount,
            used: s.usedBytes,
            free: s.freeBytes,
          ),
          // §5 fixes the stat row at three, so in-flight bytes get a quiet
          // sub-line instead of a fourth KPI (§11), and only while something
          // is actually in flight — the card's shape is unchanged otherwise.
          if (s.reservedBytes > 0) ...[
            const SizedBox(height: 8),
            _ReservedLine(bytes: s.reservedBytes),
          ],
          if (s.isEmpty) ...[
            const SizedBox(height: 8),
            EmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Your cloud has no space yet',
              subtitle:
                  'Contribute free space from this device, then add others — the pool keeps one tally of every share.',
              action: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassButton(
                    onPressed: () {
                      AppHaptics.light();
                      if (widget.onContribute != null) {
                        widget.onContribute!();
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('Pool service not connected yet.')),
                        );
                      }
                    },
                    icon: Icons.add_rounded,
                    label: 'Contribute this device',
                  ),
                  TextButton(
                    onPressed: () {
                      AppHaptics.light();
                      if (widget.onHowPoolingWorks != null) {
                        widget.onHowPoolingWorks!();
                      } else {
                        _showHowPoolingWorks(context);
                      }
                    },
                    child: const Text('How pooling works'),
                  ),
                ],
              ),
            ),
          ] else ...[
            const SizedBox(height: 4),
            _LegendChips(
              contributors: s.contributors,
              focusedIndex: _focused,
              onFocus: _focus,
            ),
          ],
        ],
      ),
    );
  }
}

void _showHowPoolingWorks(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How pooling works',
                style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700, letterSpacing: -0.3)),
            const SizedBox(height: 12),
            Text(
              'Each device contributes a slice of its free space, and the '
              'pool adds those slices into one tally, so the whole cloud '
              'reads as a single number.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Every device keeps a quota, so it never holds more than the '
              'share you allow. Revoking a device returns its slice to the '
              'pool at once.',
              style: Theme.of(ctx)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Row of three hero stats: Contributors · Used · Free (§5).
class _PoolStats extends StatelessWidget {
  const _PoolStats({
    required this.contributors,
    required this.used,
    required this.free,
  });

  final int contributors;
  final int used;
  final int free;

  @override
  Widget build(BuildContext context) {
    final valueStyle = Theme.of(context)
        .textTheme
        .titleSmall
        ?.copyWith(fontWeight: FontWeight.w700);
    final labelStyle = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    Widget stat(String label, String value) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: labelStyle, maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              Text(value, style: valueStyle),
            ],
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        stat('Contributors', '$contributors'),
        stat('Used', formatPoolSize(used)),
        stat('Free', formatPoolSize(free)),
      ],
    );
  }
}

/// Quiet sub-line under the three hero stats: quota claimed by a write that
/// has not committed yet — neither free nor used, so a card that showed only
/// Used + Free would silently lose it from both.
///
/// It renders only when something is genuinely in flight, which leaves §5's
/// three-stat row untouched for the common case. The meaning rides in a
/// tooltip because "reserved" on its own reads as space held back, not as an
/// upload mid-flight; the figure is never shown bare (§10).
class _ReservedLine extends StatelessWidget {
  const _ReservedLine({required this.bytes});

  final int bytes;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;
    return Tooltip(
      message: 'Claimed by an upload that has not finished yet. It becomes '
          'used when the write commits, or free again if it fails.',
      child: Row(
        children: [
          // Shape + word, never hue alone (§10).
          Icon(Icons.schedule_rounded, size: 13, color: muted),
          const SizedBox(width: 6),
          Text(
            '${formatPoolSize(bytes)} reserved',
            style: poolMonoDigits.copyWith(fontSize: 12, color: muted),
          ),
        ],
      ),
    );
  }
}

/// Google-One style legend: each chip repeats its colour dot, name, and bytes,
/// and taps to focus that arc (§8 segment focus).
class _LegendChips extends StatelessWidget {
  const _LegendChips({
    required this.contributors,
    required this.focusedIndex,
    required this.onFocus,
  });

  final List<PoolContributor> contributors;
  final int? focusedIndex;
  final ValueChanged<int> onFocus;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (var i = 0; i < contributors.length; i++)
          Semantics(
            button: true,
            label:
                '${contributors[i].name}, ${formatPoolSize(contributors[i].quotaBytes)}',
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onFocus(i),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: poolSegmentAt(i, brightness),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        contributors[i].name,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        formatPoolSize(contributors[i].quotaBytes),
                        style: poolMonoDigits.copyWith(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
