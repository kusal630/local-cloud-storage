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
class PoolContributorTile extends StatefulWidget {
  const PoolContributorTile({
    super.key,
    required this.contributor,
    required this.color,
    this.joinTimedOut = false,
    this.onRetryJoin,
    this.onQuotaChanged,
    this.onPromote,
    this.onViewAudit,
    this.onRevoke,
  });

  final PoolContributor contributor;

  /// Stable slot colour (`poolSegmentAt(index)`) — never derived from status.
  final Color color;

  /// The 15s join timeout has fired (§7D): pill collapses to error + Retry.
  final bool joinTimedOut;

  final VoidCallback? onRetryJoin;
  final ValueChanged<int>? onQuotaChanged;
  final VoidCallback? onPromote;
  final VoidCallback? onViewAudit;
  final VoidCallback? onRevoke;

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
    final rightLabel = c.isThisDevice
        ? 'This device'
        : (!c.isOffline && c.lastSeen != null)
            ? 'last seen ${formatRelative(c.lastSeen!)}'
            : null;

    return HapticListTile(
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
          const PopupMenuItem(
            value: 'promote',
            child: Text('Promote to primary'),
          ),
          const PopupMenuItem(
            value: 'audit',
            child: Text('View audit entry'),
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
    final c = widget.contributor;
    switch (value) {
      case 'quota':
        _showQuotaSheet();
      case 'promote':
        AppHaptics.medium(); // §9: medium = promote
        if (widget.onPromote != null) {
          widget.onPromote!();
        } else {
          AppHaptics.success();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${c.name} is now primary')),
          );
        }
      case 'audit':
        AppHaptics.light();
        if (widget.onViewAudit != null) {
          widget.onViewAudit!();
        } else {
          _showAuditSheet();
        }
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
    AppHaptics.success();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Quota set to ${formatPoolSize(saved)}')),
    );
    widget.onQuotaChanged?.call(saved);
  }

  Future<void> _showAuditSheet() async {
    final c = widget.contributor;
    final pill = _statusPill;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget row(String k, String v) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(k,
                      style: Theme.of(ctx)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(
                              color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
                  Text(v, style: poolMonoDigits.copyWith(fontSize: 13)),
                ],
              ),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Audit entry',
                    style: Theme.of(ctx)
                        .textTheme
                        .titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                row('Device', c.name),
                row('Status', pill.label),
                row('Contributes', formatPoolSize(c.quotaBytes)),
                row('Stores', formatPoolSize(c.usedBytes)),
                if (c.lastSeen != null)
                  row('Last seen', formatRelative(c.lastSeen!)),
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
        );
      },
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
                'Its ${formatPoolSize(c.quotaBytes)} leaves the pool; '
                '${formatPoolSize(c.usedBytes)} of stored chunks re-replicate.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Uploads keep working on the remaining devices while chunks '
                'are copied across.',
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
    if (widget.onRevoke != null) {
      widget.onRevoke!();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Revoking ${c.name} — re-replicating its chunks')),
      );
    }
  }
}

/// Contributors section (§6): header + `Add device`, then the card holding
/// every `PoolContributorTile` — "This device" pinned first, entrance
/// staggered 60ms per row.
class PoolContributorsCard extends StatelessWidget {
  const PoolContributorsCard({
    super.key,
    required this.contributors,
    this.onAddDevice,
    this.onQuotaChanged,
    this.onPromote,
    this.onViewAudit,
    this.onRevoke,
    this.onRetryJoin,
    this.joinTimedOut = false,
  });

  final List<PoolContributor> contributors;
  final VoidCallback? onAddDevice;
  final void Function(PoolContributor contributor, int quota)? onQuotaChanged;
  final void Function(PoolContributor contributor)? onPromote;
  final void Function(PoolContributor contributor)? onViewAudit;
  final void Function(PoolContributor contributor)? onRevoke;
  final VoidCallback? onRetryJoin;
  final bool joinTimedOut;

  @override
  Widget build(BuildContext context) {
    if (contributors.isEmpty) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final reduce = MediaQuery.of(context).disableAnimations;

    // "This device" pinned to the top; otherwise keep arrival order.
    final ordered = [
      ...contributors.where((c) => c.isThisDevice),
      ...contributors.where((c) => !c.isThisDevice),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: 'CONTRIBUTORS (${contributors.length})',
          action: TextButton(
            onPressed: () {
              AppHaptics.light();
              if (onAddDevice != null) {
                onAddDevice!();
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
            itemCount: ordered.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (context, index) {
              final c = ordered[index];
              // Slot colour comes from the *original* index so pinning or a
              // status flip never reshuffles colours (§3).
              final slot = contributors.indexOf(c);
              final tile = PoolContributorTile(
                key: ValueKey('poolTile-${c.id}'),
                contributor: c,
                color: poolSegmentAt(slot, brightness),
                joinTimedOut: joinTimedOut,
                onRetryJoin: onRetryJoin,
                onQuotaChanged: onQuotaChanged == null
                    ? null
                    : (quota) => onQuotaChanged!(c, quota),
                onPromote: onPromote == null ? null : () => onPromote!(c),
                onViewAudit:
                    onViewAudit == null ? null : () => onViewAudit!(c),
                onRevoke: onRevoke == null ? null : () => onRevoke!(c),
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
