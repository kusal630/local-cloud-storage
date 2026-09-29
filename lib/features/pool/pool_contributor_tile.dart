import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/haptics/haptic_feedback.dart';
import '../../widgets/common.dart';
import '../../widgets/haptic_widgets.dart';
import '../../widgets/pool_donut.dart';
import 'pool_models.dart';

const _gib = 1024 * 1024 * 1024;

/// One contributor row (RESEARCH/DESIGN.md §6): 40px tinted circle + device
/// icon, name + status pills, mono gives/uses figures, a `StorageMeter` of its
/// own share, and a `PopupMenuButton` for the less-frequent actions.
///
/// The row itself opens the quota sheet — the tile's primary management
/// action (§9 maps `light` to a tile tap, which `HapticListTile` fires).
class PoolContributorTile extends StatefulWidget {
  const PoolContributorTile({
    super.key,
    required this.contributor,
    required this.color,
    this.joinTimedOut = false,
    this.onRetryJoin,
    this.onQuotaChanged,
    this.onRevoke,
  });

  final PoolContributor contributor;

  /// Stable slot colour (`poolSegmentAt(index)`) — never derived from status.
  final Color color;

  /// The 15s join timeout has fired (§7D): pill collapses to error + Retry.
  final bool joinTimedOut;

  final VoidCallback? onRetryJoin;
  /// The new share, once the pool confirms it. The sheet only buzzes and
  /// reports success after this completes — never before, because a quota
  /// that did not save must not be announced as saved.
  final Future<void> Function(int quotaBytes)? onQuotaChanged;
  final Future<void> Function()? onRevoke;

  @override
  State<PoolContributorTile> createState() => _PoolContributorTileState();
}

class _PoolContributorTileState extends State<PoolContributorTile> {
  Timer? _stageTimer;
  int _stage = 0;

  static const _joinStages = [
    'Verifying pairing…',
    'Handshaking…',
  ];

  bool get _showJoinProgress =>
      widget.contributor.isJoining && !widget.joinTimedOut;

  @override
  void initState() {
    super.initState();
    _syncStages();
  }

  @override
  void didUpdateWidget(PoolContributorTile old) {
    super.didUpdateWidget(old);
    _syncStages();
  }

  void _syncStages() {
    if (_showJoinProgress && _stageTimer == null) {
      _stageTimer = Timer.periodic(const Duration(milliseconds: 2500), (_) {
        if (!mounted || !_showJoinProgress) return;
        setState(() => _stage = (_stage + 1) % (_joinStages.length + 1));
      });
    } else if (!_showJoinProgress && _stageTimer != null) {
      _stageTimer!.cancel();
      _stageTimer = null;
      _stage = 0;
    }
  }

  @override
  void dispose() {
    _stageTimer?.cancel();
    super.dispose();
  }

  IconData get _deviceIcon => switch (widget.contributor.deviceKind) {
        'laptop' => Icons.laptop,
        'tablet' => Icons.tablet,
        'server' => Icons.memory,
        _ => Icons.phone,
      };

  ({String label, Color color}) get _statusPill {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final c = widget.contributor;
    if (widget.joinTimedOut && c.isJoining) {
      return (
        label: 'Join failed',
        color: dark ? poolStatusError : poolStatusErrorLight
      );
    }
    return switch (c.status) {
      PoolContributorStatus.online => (
          label: 'Online',
          color: dark ? poolStatusOnline : poolStatusOnlineLight
        ),
      PoolContributorStatus.offline => (
          label: 'Offline',
          color: dark ? poolStatusOffline : poolStatusOfflineLight
        ),
      PoolContributorStatus.joining => (
          label: 'Joining',
          color: dark ? poolStatusJoining : poolStatusJoiningLight
        ),
      PoolContributorStatus.failed => (
          label: 'Join failed',
          color: dark ? poolStatusError : poolStatusErrorLight
        ),
    };
  }

  String get _stageText {
    final c = widget.contributor;
    if (_stage < _joinStages.length) return _joinStages[_stage];
    return 'Allocating ${formatPoolSize(c.quotaBytes)}…';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = widget.contributor;
    final pill = _statusPill;
    // §10 recency: the phrase matters exactly where the device is *gone*, so
    // offline rows carry `last seen 12m ago` and online rows (whose heartbeat
    // is current by definition) stay quiet. Never a raw timestamp.
    final rightLabel = c.isThisDevice
        ? 'This device'
        : (c.isOffline && c.lastSeen != null)
            ? 'last seen ${formatRelative(c.lastSeen!)}'
            : null;

    return HapticListTile(
      // The row's primary management action (§9: `light` on a tile tap —
      // HapticListTile fires it on the gesture).
      onTap: _showQuotaSheet,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Icon(_deviceIcon, size: 20, color: widget.color),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              c.name,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(label: pill.label, color: pill.color),
          if (c.isThisDevice) ...[
            const SizedBox(width: 8),
            StatusPill(label: 'This device', color: scheme.primary),
          ],
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showJoinProgress) ...[
              const LinearProgressIndicator(minHeight: 4),
              const SizedBox(height: 6),
              Text(
                _stageText,
                key: const ValueKey('joinStage'),
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.primary),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              'Gives ${formatPoolSize(c.quotaBytes)} · uses ${formatPoolSize(c.usedBytes)}',
              style: poolMonoDigits.copyWith(
                fontSize: 12,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            StorageMeter(
              fraction: c.usedFraction,
              usedLabel:
                  '${(c.usedFraction * 100).round()}% of its share',
              freeLabel: rightLabel,
              color: widget.color,
            ),
            if (widget.joinTimedOut && c.isJoining) ...[
              const SizedBox(height: 4),
              TextButton.icon(
                onPressed: () {
                  AppHaptics.light();
                  if (widget.onRetryJoin != null) {
                    widget.onRetryJoin!();
                  }
                },
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Actions for ${c.name}',
        icon: const Icon(Icons.more_vert),
        onOpened: () => AppHaptics.light(),
        onSelected: (value) => _onMenu(value),
        itemBuilder: (ctx) => [
          const PopupMenuItem(
            value: 'quota',
            child: Text('Set quota…'),
          ),
          PopupMenuItem(
            value: 'revoke',
            child: Text(
              'Revoke',
              style: TextStyle(
                color: Theme.of(ctx).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onMenu(String value) {
    switch (value) {
      case 'quota':
        _showQuotaSheet();
      case 'revoke':
        // Destructive — heavy feedback on the gesture (§6/README).
        AppHaptics.heavy();
        _showRevokeSheet();
    }
  }

  // -------------------------------------------------------------------------
  // Bottom sheets — quota edits and destructive confirms are never dialogs.
  // -------------------------------------------------------------------------

  Future<void> _showQuotaSheet() async {
    final c = widget.contributor;
    const min = _gib;
    final max = math.max(c.quotaBytes * 4, 10 * _gib);
    final initial = c.quotaBytes < min
        ? min
        : (c.quotaBytes > max ? max : c.quotaBytes);
    final divisions = ((max - min) / _gib).round();

    final saved = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        var current = initial;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: StatefulBuilder(
              builder: (ctx, setSheetState) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Set quota for ${c.name}',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      formatPoolSize(current),
                      style: poolMonoDigits.copyWith(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: Theme.of(ctx).colorScheme.primary,
                      ),
                    ),
                  ),
                  Slider(
                    value: current.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    divisions: divisions > 1 ? divisions : null,
                    label: formatPoolSize(current),
                    onChanged: (v) {
                      AppHaptics.selection(); // §9: selection = quota slider
                      setSheetState(() => current = v.round());
                    },
                  ),
                  Text(
                    'This device never stores more than its share of the pool.',
                    style: Theme.of(ctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, current),
                        child: Text('Save ${formatPoolSize(current)}'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    if (saved == null || !mounted) return;
    final apply = widget.onQuotaChanged;
    if (apply == null) return;

    try {
      await apply(saved);
    } catch (_) {
      // PoolScreen already named the failure and buzzed the error cue — one
      // report per failure, and never a success the pool did not accept.
      return;
    }
    if (!mounted) return;
    AppHaptics.success();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Quota set to ${formatPoolSize(saved)}')),
    );
  }

  Future<void> _showRevokeSheet() async {
    final c = widget.contributor;
    final brightness = Theme.of(context).brightness;
    final errorFill = brightness == Brightness.dark
        ? poolStatusError
        : poolStatusErrorLight;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Revoke ${c.name}?',
                style: Theme.of(ctx)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(
                'Its ${formatPoolSize(c.quotaBytes)} leaves the pool, and '
                'your files stay where they are.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Uploads keep working on the devices that remain.',
                style: Theme.of(ctx)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
              ),
              // Destructive action sits well below the fold — away from
              // thumbs (README / §6).
              const SizedBox(height: 96),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: errorFill,
                        foregroundColor: poolOnColor(errorFill, brightness),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Revoke'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    AppHaptics.medium(); // §9: medium = revoke confirm
    final revoke = widget.onRevoke;
    if (revoke != null) {
      try {
        await revoke();
      } catch (_) {
        // PoolScreen named the failure and buzzed the error cue, so there is
        // exactly one report per failure — and nothing left dangling as an
        // unhandled async error.
      }
    } else {
      // No callback means the pool service is not reachable from here, so
      // nothing was revoked. Say that instead of claiming work in progress.
      AppHaptics.error();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pool service not connected yet.')),
      );
    }
  }
}

/// Contributors section (§6): header + `Add device`, then the card holding
/// every `PoolContributorTile` — "This device" pinned first, then the
/// biggest shares, entrance staggered 60ms per row. Past [_maxVisible] the
/// list folds to a single line, so a large pool cannot push everything else
/// below the fold.
class PoolContributorsCard extends StatefulWidget {
  const PoolContributorsCard({
    super.key,
    required this.contributors,
    this.onAddDevice,
    this.onQuotaChanged,
    this.onRevoke,
    this.onRetryJoin,
    this.joinTimedOut = false,
  });

  final List<PoolContributor> contributors;
  final VoidCallback? onAddDevice;
  final Future<void> Function(PoolContributor contributor, int quota)?
      onQuotaChanged;
  final Future<void> Function(PoolContributor contributor)? onRevoke;
  final VoidCallback? onRetryJoin;
  final bool joinTimedOut;

  @override
  State<PoolContributorsCard> createState() => _PoolContributorsCardState();
}

class _PoolContributorsCardState extends State<PoolContributorsCard> {
  /// Rows shown before the "N more devices" line takes over.
  static const int _maxVisible = 6;

  /// The tail stays folded until the reader asks for it.
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    if (widget.contributors.isEmpty) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final reduce = MediaQuery.of(context).disableAnimations;

    // "This device" first, then the largest shares: a pool reads from the
    // devices carrying most of it, and share order beats arrival order.
    final pinned = [
      for (final c in widget.contributors)
        if (c.isThisDevice) c,
    ];
    final others = [
      for (final c in widget.contributors)
        if (!c.isThisDevice) c,
    ]..sort((a, b) => b.quotaBytes.compareTo(a.quotaBytes));
    final ordered = [...pinned, ...others];

    final visible = _showAll || ordered.length <= _maxVisible
        ? ordered
        : ordered.take(_maxVisible).toList();
    final hiddenCount = ordered.length - visible.length;
    final hiddenBytes = ordered
        .skip(visible.length)
        .fold<int>(0, (sum, c) => sum + c.quotaBytes);
    // One label for the whole tail, so collapsing costs no information —
    // the reader still sees how many devices and how much quota are hidden.
    final tailLabel = '$hiddenCount more '
        '${hiddenCount == 1 ? 'device' : 'devices'} · '
        '${formatPoolSize(hiddenBytes)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'CONTRIBUTORS (${widget.contributors.length})',
          action: TextButton(
            onPressed: () {
              AppHaptics.light();
              if (widget.onAddDevice != null) {
                widget.onAddDevice!();
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('Pool service not connected yet.')),
                );
              }
            },
            child: const Text('Add device'),
          ),
        ),
        Card(
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: visible.length + (hiddenCount > 0 ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) {
              if (index >= visible.length) {
                return ListTile(
                  dense: true,
                  title: Text(tailLabel),
                  trailing: const Icon(Icons.expand_more),
                  onTap: () {
                    AppHaptics.light();
                    setState(() => _showAll = true);
                  },
                );
              }
              final c = visible[index];
              // Slot colour comes from the *original* index so pinning or a
              // status flip never reshuffles colours (§3).
              final slot = widget.contributors.indexOf(c);
              final tile = PoolContributorTile(
                key: ValueKey('poolTile-${c.id}'),
                contributor: c,
                color: poolSegmentAt(slot, brightness),
                joinTimedOut: widget.joinTimedOut,
                onRetryJoin: widget.onRetryJoin,
                onQuotaChanged: widget.onQuotaChanged == null
                    ? null
                    : (quota) => widget.onQuotaChanged!(c, quota),
                onRevoke: widget.onRevoke == null
                    ? null
                    : () => widget.onRevoke!(c),
              );
              if (reduce) return tile;
              return tile
                  .animate(delay: Duration(milliseconds: 60 * index))
                  .fadeIn(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOut)
                  .slideY(
                      begin: 0.06,
                      end: 0,
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOut);
            },
          ),
        ),
      ],
    );
  }
}
