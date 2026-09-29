import 'package:flutter/material.dart';

import '../../core/haptics/haptic_feedback.dart';
import '../../widgets/common.dart';
import '../../widgets/pool_donut.dart';

/// 1 GiB — the smallest share a device can give, and the slider's step.
const _gib = 1024 * 1024 * 1024;

/// Capacity floor the sheet points at while the pool is still small.
///
/// Product rule, stated in the copy instead of implied: below this floor the
/// pool fills past the 90%-full write-stall line long before a household
/// library fits on it twice, so the UI only *promises* 2-device redundancy
/// once the pool clears 40 GB. Above the floor the milestones step in 10 GB
/// increments.
const _redundancyFloorBytes = 40 * _gib;

/// Milestone step above the floor (goal-gradient: show the next step only).
const _milestoneStepBytes = 10 * _gib;

/// Everything the "Contribute this device" sheet needs to render, projected
/// and report back. The pool service slice builds this from its last
/// `PoolStatus` snapshot; the UI never derives totals of its own
/// (`pool_models.dart` §4: totals are host-derived).
class ContributeSheetArgs {
  const ContributeSheetArgs({
    required this.currentPoolBytes,
    required this.thisDeviceFreeBytes,
    required this.isContributing,
    required this.thisDeviceQuotaBytes,
    required this.onContribute,
    required this.onStop,
    this.thisDeviceUsedBytes,
    this.thisDeviceSlotIndex,
  });

  /// What the pool holds right now (already includes this device's share when
  /// [isContributing] is true).
  final int currentPoolBytes;

  /// Real free space on this device — the slider's maximum. Never fabricate
  /// this number: the sheet must not offer space the device does not have.
  final int thisDeviceFreeBytes;

  /// True when this device is already in the pool (row + destructive stop).
  final bool isContributing;

  /// This device's current share of the pool (0 when not contributing).
  final int thisDeviceQuotaBytes;

  /// Optional: what this device stores today. When the caller supplies it the
  /// row reads `Gives 10 GB · uses 3.2 GB`; when it is unknown the row says
  /// what it actually knows (`… GB free`) rather than inventing a figure.
  final int? thisDeviceUsedBytes;

  /// Optional: this device's slot index in the contributor list, so the share
  /// bar uses the *same* colour as its arc in the ring (§3 — colours are
  /// assigned by stable slot, never by status). Falls back to the brand
  /// primary when the caller does not say.
  final int? thisDeviceSlotIndex;

  /// Add (or re-size) this device's share. Errors are surfaced by the sheet
  /// as "name the fix + Retry".
  final Future<void> Function(int quotaBytes) onContribute;

  /// Remove this device from the pool. Called only after the consequence
  /// sheet is confirmed.
  final Future<void> Function() onStop;
}

/// Opens the **Contribute this device** bottom sheet (radius 24, DESIGN.md §6).
///
/// The sheet carries exactly one decision — how much space *this* device
/// gives (Hick's law) — and ends on a success haptic + confirmation
/// (peak–end rule). Destructive and audit actions stay on the contributor
/// tile.
Future<void> showContributeSheet(
  BuildContext context, {
  required ContributeSheetArgs args,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Spelled out (rather than relying on `bottomSheetTheme`) so the sheet
    // keeps the DESIGN.md §6 radius 24 geometry wherever it is shown.
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheetContext) => ContributeSheet(args: args),
  );
}

class ContributeSheet extends StatefulWidget {
  const ContributeSheet({super.key, required this.args});

  final ContributeSheetArgs args;

  @override
  State<ContributeSheet> createState() => _ContributeSheetState();
}

class _ContributeSheetState extends State<ContributeSheet> {
  static const int _minQuota = _gib;
  static const List<int> _presets = <int>[1 * _gib, 10 * _gib, 25 * _gib];

  late int _quota;
  bool _busy = false;
  String? _error;
  Future<void> Function()? _retry;
  bool _reduce = false;

  ContributeSheetArgs get _args => widget.args;

  @override
  void initState() {
    super.initState();
    _quota = _startingQuota();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.of(context).disableAnimations;
  }

  // -------------------------------------------------------------------------
  // Geometry & projections
  // -------------------------------------------------------------------------

  /// Largest whole-GB share that still fits inside the device's real free
  /// space (never round *up* past what is there).
  int get _maxQuota {
    final free = _args.thisDeviceFreeBytes;
    if (free <= _minQuota) return _minQuota;
    return _minQuota + ((free - _minQuota) ~/ _gib) * _gib;
  }

  bool get _hasRoom => _args.thisDeviceFreeBytes >= _minQuota;

  /// The slider needs `max > min`; a device with 1–2 GB free just gets the
  /// smallest share with an honest note instead of a broken control.
  bool get _canAdjust => _maxQuota > _minQuota;

  int get _divisions => (_maxQuota - _minQuota) ~/ _gib;

  int _startingQuota() {
    if (_args.thisDeviceFreeBytes < _minQuota) return _minQuota;
    // Endowed progress: the slider opens partway up the ladder (10 GB), so
    // the first decision is a *share*, not a start-from-zero.
    final start = _args.isContributing && _args.thisDeviceQuotaBytes > 0
        ? _args.thisDeviceQuotaBytes
        : 10 * _gib;
    if (start < _minQuota) return _minQuota;
    return start > _maxQuota ? _maxQuota : start;
  }

  /// What the pool would hold at this quota. Deltas only — the host owns the
  /// totals, the sheet just shows the next one.
  int get _projectedPoolBytes {
    final delta =
        _quota - (_args.isContributing ? _args.thisDeviceQuotaBytes : 0);
    final projected = _args.currentPoolBytes + delta;
    return projected < 0 ? 0 : projected;
  }

  /// True when someone else is already in the pool — without a second device
  /// no capacity figure can honestly promise a second copy.
  bool get _hasOtherDevice {
    final others =
        _args.currentPoolBytes -
        (_args.isContributing ? _args.thisDeviceQuotaBytes : 0);
    return others > 0;
  }

  bool get _redundancyReached =>
      _projectedPoolBytes >= _redundancyFloorBytes && _hasOtherDevice;

  /// Goal-gradient: always the *next* milestone, never the whole ladder.
  String get _milestoneLine {
    final projected = _projectedPoolBytes;
    if (projected < _redundancyFloorBytes) {
      final gap = formatPoolSize(_redundancyFloorBytes - projected);
      return _hasOtherDevice
          ? '$gap more unlocks 2-device redundancy'
          : '$gap more reaches ${formatPoolSize(_redundancyFloorBytes)} — '
                'the room two copies need';
    }
    final next = ((projected ~/ _milestoneStepBytes) + 1) * _milestoneStepBytes;
    final gap = formatPoolSize(next - projected);
    return '$gap more keeps two copies of '
        '${formatPoolSize(next ~/ 2)} of files';
  }

  String get _growthCaption {
    final projected = formatPoolSize(_projectedPoolBytes);
    final quota = formatPoolSize(_quota);
    if (!_args.isContributing) {
      return 'pool becomes $projected when you contribute $quota';
    }
    if (_quota == _args.thisDeviceQuotaBytes) {
      return 'pool becomes $projected — this device already gives $quota';
    }
    return 'pool becomes $projected at $quota from this device';
  }

  String get _submitLabel =>
      _args.isContributing ? 'Save ${formatPoolSize(_quota)}' : 'Contribute';

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _submit() async {
    if (_busy || !_hasRoom) return;
    AppHaptics.light(); // §9: on the gesture, before the async result
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _args.onContribute(_quota);
      if (!mounted) return;
      // Peak–end rule: the flow ends on the success pattern + a confirmation
      // that states the new pool total.
      AppHaptics.success();
      final message = _args.isContributing
          ? 'Quota updated to ${formatPoolSize(_quota)}'
          : '${formatPoolSize(_quota)} added · the pool is now '
                '${formatPoolSize(_projectedPoolBytes)}';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      AppHaptics.error();
      setState(() {
        _busy = false;
        _error = _args.isContributing
            ? "Couldn't update this device's quota. Check that this device "
                  'is on the same network as the host, then retry.'
            : "Couldn't add this device to the pool. Check that this device "
                  'is on the same network as the host, then retry.';
        _retry = _submit;
      });
    }
  }

  /// Destructive: heavy feedback on the gesture, then the consequence sheet
  /// (§6 / README — destructive confirmation lives away from thumbs).
  Future<void> _requestStop() async {
    AppHaptics.heavy();
    final quota = _args.isContributing ? _args.thisDeviceQuotaBytes : _quota;
    final brightness = Theme.of(context).brightness;
    final errorFill = brightness == Brightness.dark
        ? poolStatusError
        : poolStatusErrorLight;
    final remaining = _args.currentPoolBytes - quota;

    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Stop contributing?',
                style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Its ${formatPoolSize(quota)} leaves the pool, and your '
                'files stay where they are.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'The pool drops to '
                '${formatPoolSize(remaining < 0 ? 0 : remaining)} and uploads '
                'keep working on the devices that stay. Nothing is deleted.',
                style: Theme.of(ctx).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
              ),
              // Loss aversion, made concrete: state what goes *before* the
              // user commits.
              const SizedBox(height: 96),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 44),
                      ),
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      key: const Key('confirmStop'),
                      style: FilledButton.styleFrom(
                        backgroundColor: errorFill,
                        foregroundColor: poolOnColor(errorFill, brightness),
                      ),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Stop contributing'),
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
    AppHaptics.medium(); // §9: confirm of a destructive action
    await _runStop();
  }

  Future<void> _runStop() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _args.onStop();
      if (!mounted) return;
      AppHaptics.success(); // peak–end: leave on the success pattern
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This device left the pool · its reserved space was released',
          ),
        ),
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      AppHaptics.error();
      setState(() {
        _busy = false;
        _error =
            "Couldn't stop contributing — this device still holds "
            '${formatPoolSize(_args.isContributing ? _args.thisDeviceQuotaBytes : _quota)} '
            'of the pool. Check that this device is on the same network as '
            'the host, then retry.';
        _retry = _runStop;
      });
    }
  }

  Future<void> _retryAction() async {
    final retry = _retry;
    if (retry == null || _busy) return;
    AppHaptics.light();
    await retry();
  }

  // -------------------------------------------------------------------------
  // Layout
  // -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 20),
                child: _sheetBody(context),
              ),
            ),
            _actions(context),
          ],
        ),
      ),
    );
  }

  Widget _sheetBody(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final errorFill = brightness == Brightness.dark
        ? poolStatusError
        : poolStatusErrorLight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Contribute this device',
          style: Theme.of(context).textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
        ),
        const SizedBox(height: 16),
        _hero(context),
        if (_args.isContributing) ...[
          const SizedBox(height: 20),
          _thisDeviceRow(context),
        ],
        const SizedBox(height: 24),
        _quotaSection(context),
        const SizedBox(height: 24),
        _privacySection(context),
        if (_args.isContributing) ...[
          const SizedBox(height: 24),
          _stopSection(context, errorFill),
        ],
      ],
    );
  }

  /// Goal-gradient + endowed progress: current total → projected total, then
  /// the single next milestone with its distance.
  Widget _hero(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final projected = formatPoolSize(_projectedPoolBytes);
    final milestone = _milestoneLine;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PROJECTED POOL',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            color: scheme.primary,
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          label:
              'Pool grows from ${formatPoolSize(_args.currentPoolBytes)} '
              'to $projected',
          excludeSemantics: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                formatPoolSize(_args.currentPoolBytes),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.arrow_forward_rounded,
                size: 16,
                color: scheme.outline,
              ),
              const SizedBox(width: 8),
              Text(
                projected,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                  color: scheme.primary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: _reduce ? Duration.zero : const Duration(milliseconds: 160),
          child: Text(
            _growthCaption,
            key: ValueKey<String>(_growthCaption),
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: _reduce ? Duration.zero : const Duration(milliseconds: 160),
          child: Text(
            milestone,
            key: ValueKey<String>(milestone),
            style: Theme.of(context).textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600, color: scheme.primary),
          ),
        ),
        if (_redundancyReached) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(
                Icons.check_circle_outline_rounded,
                size: 16,
                color: poolStatusOnline,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  '2-device redundancy on — every file is kept twice',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: poolStatusOnline,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// This device's own row (§6) when it is already in the pool.
  Widget _thisDeviceRow(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final quota = _args.thisDeviceQuotaBytes;
    final used = _args.thisDeviceUsedBytes;
    final knownShare = used != null && quota > 0;
    final slot = _args.thisDeviceSlotIndex;
    // §3: the bar borrows its arc colour when the caller knows the slot.
    final accent = slot == null
        ? scheme.primary
        : poolSegmentAt(slot, brightness);
    final poolShare = _args.currentPoolBytes > 0
        ? (quota / _args.currentPoolBytes).clamp(0.0, 1.0)
        : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.phone, size: 16, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                used == null
                    ? 'Gives ${formatPoolSize(quota)} · '
                          '${formatPoolSize(_args.thisDeviceFreeBytes)} free'
                    : 'Gives ${formatPoolSize(quota)} · uses '
                          '${formatPoolSize(used)}',
                style: poolMonoDigits.copyWith(
                  fontSize: 13,
                  color: scheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        StorageMeter(
          // Share bar: how much of the *pool* this device carries, or how
          // full its own share is when the caller supplied the used figure.
          fraction: knownShare ? (used / quota).clamp(0.0, 1.0) : poolShare,
          usedLabel: knownShare
              ? '${((used / quota) * 100).round()}% of its share'
              : '${(poolShare * 100).round()}% of the pool',
          freeLabel: 'This device',
          color: accent,
        ),
      ],
    );
  }

  Widget _quotaSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'SPACE FROM THIS DEVICE'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              formatPoolSize(_quota),
              style: poolMonoDigits.copyWith(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: scheme.primary,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _hasRoom
                    ? '${formatPoolSize(_args.thisDeviceFreeBytes)} free on '
                          'this device'
                    : 'This device has less than 1 GB free, so it cannot '
                          'contribute right now.',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _hasRoom ? scheme.onSurfaceVariant : scheme.error,
                ),
              ),
            ),
          ],
        ),
        if (_canAdjust)
          Slider(
            value: _quota.toDouble(),
            min: _minQuota.toDouble(),
            max: _maxQuota.toDouble(),
            divisions: _divisions,
            label: formatPoolSize(_quota),
            onChanged: !_hasRoom
                ? null
                : (value) {
                    // §9: selection fires on the gesture, not after the rebuild.
                    AppHaptics.selection();
                    setState(() => _quota = value.round());
                  },
          )
        else if (_hasRoom) ...[
          const SizedBox(height: 4),
          Text(
            '1 GB is the smallest share — this device has no more to give.',
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in _presets)
              _PresetChip(
                label: '${preset ~/ _gib} GB',
                selected: _quota == preset,
                enabled: _hasRoom && preset >= _minQuota && preset <= _maxQuota,
                onTap: () => setState(() => _quota = preset),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Shares step in 1 GB units and never exceed what this device has '
          'free.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: scheme.outline),
        ),
      ],
    );
  }

  /// Honest privacy explainer: what is stored, what this device can see, and
  /// that the contribution is capped and revocable.
  Widget _privacySection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'PRIVACY'),
        _InfoRow(
          icon: Icons.lock_outline,
          text:
              'Files you upload stay on the host you upload to — no file '
              'data is sent to any device in this pool.',
        ),
        const SizedBox(height: 12),
        _InfoRow(
          icon: Icons.visibility_off_outlined,
          text:
              'This device holds reserved space and a quota count only — '
              'never file names or contents.',
        ),
        const SizedBox(height: 12),
        _InfoRow(
          icon: Icons.undo_rounded,
          text:
              'Capped at ${formatPoolSize(_quota)} and revocable at any '
              'time: you stay in control of the share.',
        ),
      ],
    );
  }

  /// Destructive action: sits deep in the scroll content, far from the pinned
  /// thumb zone (README: destructive actions live away from thumbs).
  Widget _stopSection(BuildContext context, Color errorFill) {
    final brightness = Theme.of(context).brightness;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        const SizedBox(height: 16),
        Text(
          'This device only reserves space for the pool. Leaving it takes '
          'no files with you and deletes nothing.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 56),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                key: const Key('stopContribute'),
                style: FilledButton.styleFrom(
                  backgroundColor: errorFill,
                  foregroundColor: poolOnColor(errorFill, brightness),
                ),
                onPressed: _busy ? null : _requestStop,
                child: const Text('Stop contributing'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Pinned action bar — thumb-safe: the primary decision always sits below
  /// the fold of the scroll content, in the bottom quarter of the sheet.
  Widget _actions(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            _errorBlock(context),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const Key('contributeSubmit'),
                  onPressed: _busy || !_hasRoom ? null : _submit,
                  child: Text(_submitLabel),
                ),
              ),
            ],
          ),
          Center(
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
              onPressed: _busy ? null : _showHowPoolingWorks,
              child: const Text('How pooling works'),
            ),
          ),
        ],
      ),
    );
  }

  /// "Errors name the fix and offer Retry" — the app's existing pattern.
  Widget _errorBlock(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_error!, style: TextStyle(color: scheme.onErrorContainer)),
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const Key('retryAction'),
                  onPressed: _retry == null ? null : _retryAction,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showHowPoolingWorks() {
    AppHaptics.light();
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How pooling works',
                style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Each device contributes a capped slice of its free space, '
                'and the pool keeps one tally of them all, so the whole '
                'cloud reads as a single number.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Reserved space is not file space: nothing is copied onto '
                'a contributing device, so the pool holds your share and '
                'none of your files.',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'You choose the share and you can stop at any time: the '
                'space this device reserved returns to it, and your files '
                'are never moved.',
                style: Theme.of(ctx).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(ctx).colorScheme.outline),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(64, 44)),
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
}

/// Preset quota chip: radius 8 (chips), ≥44px tall, selected state carried by
/// a check glyph + `Semantics(selected:)` — never by hue alone.
class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final border = selected ? scheme.primary : scheme.outlineVariant;
    return Semantics(
      selected: selected,
      enabled: enabled,
      button: true,
      child: InkWell(
        onTap: enabled
            ? () {
                // §9: selection haptic on the gesture.
                AppHaptics.selection();
                onTap();
              }
            : null,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primaryContainer.withValues(alpha: 0.6)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border, width: selected ? 1.5 : 1),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: enabled ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: enabled ? scheme.onSurface : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Privacy bullet: decorative icon + one honest sentence (≥44px row).
class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(child: Icon(icon, size: 18, color: scheme.primary)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4),
          ),
        ),
      ],
    );
  }
}
