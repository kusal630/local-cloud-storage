import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/core/errors/app_exceptions.dart';
import 'package:localvault/core/haptics/haptic_feedback.dart';
import 'package:localvault/core/utils/disk_space_compat.dart';
import 'package:localvault/data/models/storage_status.dart';
import 'package:localvault/features/pool/contribute_sheet.dart';
import 'package:localvault/widgets/common.dart';
import 'package:localvault/widgets/pool_donut.dart';
import 'package:path_provider/path_provider.dart';

// ---------------------------------------------------------------------------
// Graded capacity thresholds — RESEARCH/UX_BENCHMARK.md item 2.
//
// A single 90% cliff gives nobody time to act: TrueNAS turns its ring amber
// and prints a line under it, Ceph colours the *number* band by band
// (RESEARCH/DESIGN.md §1). Three bands, and never hue alone — `watch` and
// `warn` both ship a sentence, `full` ships the error card.
// ---------------------------------------------------------------------------

/// 75% warms the hero number, 85% warms the ring and adds a sentence,
/// 90% keeps the existing error card.
enum _UsageLevel { ok, watch, warn, full }

_UsageLevel _levelOf(double fraction) {
  if (fraction >= 0.9) return _UsageLevel.full;
  if (fraction >= 0.85) return _UsageLevel.warn;
  if (fraction >= 0.75) return _UsageLevel.watch;
  return _UsageLevel.ok;
}

/// The app's existing warning amber — the same token the pool health banner
/// uses, so "warning" reads identically on both screens. The light/dark pair
/// already clears 4.5:1 as text (`pool_donut.dart` §3).
Color _amberOf(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return dark ? poolStatusDegraded : poolStatusDegradedLight;
}

/// Words for the two warning bands. An amber number with no sentence leaves
/// the user guessing what changed (calm design: unexplained states create
/// anxiety), so hue is never the only carrier of the message.
Widget _usageNote(BuildContext context, _UsageLevel level, double fraction) {
  if (level != _UsageLevel.watch && level != _UsageLevel.warn) {
    return const SizedBox.shrink();
  }
  final tone = _amberOf(context);
  final style = Theme.of(context)
      .textTheme
      .bodyMedium
      ?.copyWith(color: tone, fontWeight: FontWeight.w600);
  if (level == _UsageLevel.watch) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        'Storage is ${(fraction * 100).round()}% full.',
        style: style,
      ),
    );
  }
  return Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Row(
      children: [
        Icon(Icons.warning_amber_rounded, size: 16, color: tone),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Almost full — free up space soon.', style: style),
        ),
      ],
    ),
  );
}

/// The 75–85% band is the one place where the ring and the hero number
/// deliberately disagree — the number warms, the ring stays calm — and
/// `StorageDonut` paints both from a single `color`. Every other band is one
/// colour end to end and stays on the shared widget.
///
/// Everything else (geometry, type styles, the `SemanticsRole.status` label)
/// mirrors `StorageDonut` so the pair reads as one widget. If `StorageDonut`
/// ever grows a `centerColor` parameter this can be deleted.
class _SplitToneDonut extends StatelessWidget {
  const _SplitToneDonut({
    required this.fraction,
    required this.usedLabel,
    required this.freeLabel,
    required this.numberColor,
  });

  final double fraction;
  final String usedLabel;
  final String? freeLabel;
  final Color numberColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Same geometry as `StorageDonut`'s defaults, so the two swap in place.
    const size = 120.0;
    const strokeWidth = 10.0;
    final clamped = fraction.clamp(0.0, 1.0);
    final pct = (clamped * 100).round();
    return Semantics(
      label: 'Storage in use',
      value: <String>[
        '$pct%',
        if (usedLabel.isNotEmpty) usedLabel,
        if (freeLabel != null && freeLabel!.isNotEmpty) freeLabel!,
      ].join(', '),
      role: SemanticsRole.status,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: clamped,
                strokeWidth: strokeWidth,
                // The ring stays on the neutral brand colour in this band.
                color: scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
                strokeCap: StrokeCap.round,
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$pct%',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: numberColor,
                      ),
                ),
                Text(
                  usedLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});
  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  StorageStatus? _status;
  bool _loading = false;
  String? _error;

  /// When the numbers behind this screen last landed, plus the freshness
  /// words rendered from them (UX_BENCHMARK §9): a storage tab left open
  /// has to be able to say how old its figures are.
  DateTime? _updatedAt;
  String? _freshnessLine;
  Timer? _freshnessTimer;

  @override
  void initState() {
    super.initState();
    _load();
    // Keep "Updated 8s ago" telling the truth while the screen sits still,
    // repainting only when the words would actually change.
    _freshnessTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      final at = _updatedAt;
      if (at == null || !mounted) return;
      final next = 'Updated ${formatRelative(at)}';
      if (next == _freshnessLine) return;
      setState(() => _freshnessLine = next);
    });
  }

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(fileServiceProvider);
      final status = await svc.storageStatus();
      setState(() {
        _status = status;
        _loading = false;
        _updatedAt = DateTime.now();
        _freshnessLine = 'Updated ${formatRelative(_updatedAt!)}';
      });
    } catch (e) {
      setState(() {
        // Never a raw exception in the UI — name the cause and the next
        // step instead (DESIGN §10; RESEARCH/UI_BACKLOG.md honest failures).
        _error = e is AppException
            ? e.message
            : 'Could not read how much space is in use. Check that this '
                'device can reach your host, then try again.';
        _loading = false;
      });
    }
  }

  /// Coarse device class reported when this device joins the pool — the same
  /// answer `lib/app/router.dart` gives the pool screen's contribute action.
  String _deviceKindOfThisDevice() =>
      (Platform.isAndroid || Platform.isIOS) ? 'phone' : 'laptop';

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Opens the quota sheet — the very same `ContributeSheet` the pool screen
  /// opens (RESEARCH/UX_BENCHMARK.md item 1), wired from the providers the
  /// router hands `PoolScreen`, so "Raise quota" reaches one decision surface
  /// instead of a second, home-grown one.
  Future<void> _openQuotaSheet() async {
    AppHaptics.light();
    try {
      final docs = await getApplicationDocumentsDirectory();
      // The contributor node writes here, so this is the volume whose free
      // space bounds the slider — never a fabricated maximum.
      final space = await DiskSpaceCompat.getSpace(docs.path);
      final free = space?.free ?? 0;
      if (free <= 0) {
        _snack(
            "This device's free space could not be read, so it has nothing "
            'to offer the pool.');
        return;
      }
      final status = await ref.read(poolServiceProvider).fetchStatus();
      final agent = await ref.read(contributorAgentProvider.future);
      if (!mounted) return;
      final index = status.contributors.indexWhere((c) => c.isThisDevice);
      final me = index < 0 ? null : status.contributors[index];
      await showContributeSheet(
        context,
        args: ContributeSheetArgs(
          currentPoolBytes: status.usedBytes,
          thisDeviceFreeBytes: free,
          isContributing: me != null,
          thisDeviceQuotaBytes: me?.quotaBytes ?? 0,
          thisDeviceUsedBytes: me?.usedBytes,
          thisDeviceSlotIndex: index < 0 ? null : index,
          // Thrown errors are the sheet's to render — it owns the retry copy.
          onContribute: (quota) => agent.start(
            quotaBytes: quota,
            deviceKind: _deviceKindOfThisDevice(),
          ),
          onStop: () => agent.stop(),
        ),
      );
    } catch (e) {
      _snack(e is AppException
          ? e.message
          : 'Could not open the quota sheet. Check that your host is '
              'reachable, then try again.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Graded thresholds (item 2): one level drives the ring, the hero number
    // and whether the error card's verbs are on screen.
    final fraction = _status?.usedFraction ?? 0;
    final level = _levelOf(fraction);
    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _status == null
                  ? const EmptyState(
                      icon: Icons.sd_storage,
                      title: 'No storage info',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          // Entry point to the v2.4.0 pooled cloud (§5).
                          Card(
                            child: ListTile(
                              leading: Icon(Icons.cloud_outlined,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary),
                              title: const Text('Pooled cloud'),
                              subtitle: const Text(
                                  'Contribute free space from several devices'),
                              trailing:
                                  const Icon(Icons.chevron_right_rounded),
                              onTap: () =>
                                  context.push('/client/storage/pool'),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (level == _UsageLevel.full)
                            Card(
                              color: scheme.errorContainer
                                  .withValues(alpha: 0.7),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Icon(Icons.warning_rounded,
                                            color: scheme.onErrorContainer),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Text(
                                            'Storage is ${(_status!.usedFraction * 100).round()}% full. Free space or grow the quota before uploads start failing.',
                                            style: TextStyle(
                                                color:
                                                    scheme.onErrorContainer),
                                          ),
                                        ),
                                      ],
                                    ),
                                    // A warning with no verb forces the user
                                    // to hunt: the fastest fix first, then
                                    // the longer one (Google's full-account
                                    // flow). Theme floors keep both at ≥44px
                                    // tall; `Wrap` keeps them side by side
                                    // only while there is room.
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 4,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        FilledButton(
                                          onPressed: () {
                                            AppHaptics.light();
                                            context.go('/client/trash');
                                          },
                                          child: const Text('Free up space'),
                                        ),
                                        TextButton(
                                          onPressed: _openQuotaSheet,
                                          child: const Text('Raise quota'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (level == _UsageLevel.full)
                            const SizedBox(height: 16),
                          // Overview card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SectionHeader(title: 'DISK USAGE'),
                                  const SizedBox(height: 8),
                                  Center(
                                    child: _gradedDonut(context, fraction, level),
                                  ),
                                  _freshnessRow(context),
                                  _usageNote(context, level, fraction),
                                  const SizedBox(height: 16),
                                  _buildRow('Total', formatBytes(_status!.total)),
                                  _buildRow('Free', formatBytes(_status!.free)),
                                  _buildRow('Used', formatBytes(_status!.used)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Vault card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SectionHeader(title: 'VAULT USAGE'),
                                  StorageMeter(
                                    fraction: _status!.vaultFraction,
                                    usedLabel:
                                        'Vault: ${formatBytes(_status!.vaultUsage)}',
                                    freeLabel:
                                        'Trash: ${formatBytes(_status!.trashUsage)}',
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(height: 8),
                                  _buildRow(
                                      'Vault', formatBytes(_status!.vaultUsage)),
                                  _buildRow('Trash',
                                      formatBytes(_status!.trashUsage)),
                                  _buildRow(
                                      'Total Vault',
                                      formatBytes(
                                          _status!.vaultUsage + _status!.trashUsage)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          const _BreakdownCard(),
                          const SizedBox(height: 16),
                          const _DuplicatesCard(),
                        ],
                      ),
                    ),
    );
  }

  /// "Updated 8s ago" under the hero — the honesty line for numbers this
  /// screen does not poll (UX_BENCHMARK §9).
  Widget _freshnessRow(BuildContext context) {
    final at = _updatedAt;
    if (at == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.schedule_rounded,
              size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            _freshnessLine ?? 'Updated ${formatRelative(at)}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Ring + hero colour for the current band (RESEARCH/DESIGN.md §1).
  ///
  /// Below 75% nothing is coloured: a usage ring painted red at 5% teaches
  /// people to ignore red. 75–85% warms only the hero number; from 85% the
  /// ring joins it; at 90% both go red — exactly where the error card lands,
  /// and the colour this screen has always used for "storage is full".
  Widget _gradedDonut(
    BuildContext context,
    double fraction,
    _UsageLevel level,
  ) {
    final scheme = Theme.of(context).colorScheme;
    const usedLabel = 'Used';
    final freeLabel = 'Free: ${formatBytes(_status!.free)}';
    return switch (level) {
      _UsageLevel.ok => StorageDonut(
          fraction: fraction,
          usedLabel: usedLabel,
          freeLabel: freeLabel,
          color: scheme.primary,
        ),
      _UsageLevel.watch => _SplitToneDonut(
          fraction: fraction,
          usedLabel: usedLabel,
          freeLabel: freeLabel,
          numberColor: _amberOf(context),
        ),
      _UsageLevel.warn => StorageDonut(
          fraction: fraction,
          usedLabel: usedLabel,
          freeLabel: freeLabel,
          color: _amberOf(context),
        ),
      _UsageLevel.full => StorageDonut(
          fraction: fraction,
          usedLabel: usedLabel,
          freeLabel: freeLabel,
          color: scheme.error,
        ),
    };
  }

  Widget _buildRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}

class _BreakdownCard extends ConsumerWidget {
  const _BreakdownCard();

  static const _colors = {
    'images': Color(0xFF7C4DFF),
    'video': Color(0xFFE040FB),
    'audio': Color(0xFF00ACC1),
    'docs': Color(0xFF43A047),
    'archives': Color(0xFFFB8C00),
    'other': Color(0xFF90A4AE),
  };

  static const _labels = {
    'images': 'Images',
    'video': 'Video',
    'audio': 'Audio',
    'docs': 'Documents',
    'archives': 'Archives',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'BY TYPE'),
            FutureBuilder<Map<String, int>>(
              future:
                  ref.read(fileServiceProvider).storageBreakdown(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  // Cause + next step in plain words, not the exception.
                  return Text(
                      "Couldn't read the breakdown by type. Pull down to "
                      'refresh and try again.',
                      style: Theme.of(context).textTheme.bodySmall);
                }
                if (!snapshot.hasData) return const LoadingIndicator();
                final map = snapshot.data!;
                final total =
                    map.values.fold<int>(0, (a, b) => a + b);
                if (total <= 0) {
                  return const Text('Vault is empty.');
                }
                return Column(
                  children: [
                    for (final key in _labels.keys)
                      if ((map[key] ?? 0) > 0)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 5),
                          child: StorageMeter(
                            fraction: map[key]! / total,
                            usedLabel: _labels[key]!,
                            freeLabel: formatBytes(map[key]!),
                            color: _colors[key],
                          ),
                        ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Duplicate finder: groups sharing content, trash extras in one tap.
class _DuplicatesCard extends ConsumerStatefulWidget {
  const _DuplicatesCard();
  @override
  ConsumerState<_DuplicatesCard> createState() => _DuplicatesCardState();
}

class _DuplicatesCardState extends ConsumerState<_DuplicatesCard> {
  List<DuplicateGroup>? _groups;
  String? _error;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups =
          await ref.read(fileServiceProvider).listDuplicates();
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _error = null;
      });
    } catch (_) {
      // Surface the failure instead of spinning forever (DESIGN: honest
      // failure states — a stuck spinner reads as "still loading").
      if (!mounted) return;
      setState(() =>
          _error = "Couldn't load the duplicates list. Tap Retry to try again.");
    }
  }

  Future<void> _trashExtras(DuplicateGroup group) async {
    // Keep the oldest copy, trash the rest.
    final extras = group.files.skip(1).toList();
    if (extras.isEmpty) return;
    final count = extras.length;
    final label =
        Intl.pluralLogic(count, one: 'duplicate', other: 'duplicates');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Trash $count $label?'),
        content: Text(
            'Keeps the oldest copy of "${extras.first.name}" and moves the rest to trash.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Trash')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      final svc = ref.read(fileServiceProvider);
      for (final f in extras) {
        await svc.deleteFile(f.id);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      // Cause + next step, never the raw exception (DESIGN §10).
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            e is AppException
                ? e.message
                : 'Could not move the extra copies to trash. Check that '
                    'this device is still connected, then try again.',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'DUPLICATES'),
            if (_error != null)
              ErrorState(
                message: _error!,
                onRetry: () {
                  setState(() => _error = null);
                  _load();
                },
              )
            else if (_groups == null)
              const LoadingIndicator()
            else if (_groups!.isEmpty)
              Text('No duplicate files — every byte is unique.',
                  style: Theme.of(context).textTheme.bodySmall)
            else
              for (final g in _groups!)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${g.files.length}× ${g.files.first.name} • wastes ${formatBytes(g.wastedBytes)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton(
                            onPressed: _working
                                ? null
                                : () => _trashExtras(g),
                            child: const Text('Clean'),
                          ),
                        ],
                      ),
                      for (final f in g.files)
                        Text('• ${f.name}',
                            style:
                                Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}