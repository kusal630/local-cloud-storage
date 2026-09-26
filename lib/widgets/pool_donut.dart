import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';

// ---------------------------------------------------------------------------
// Palette tokens — RESEARCH/DESIGN.md §3. Slot order is stable (assigned by
// contributor slot index, never by status) so segments never reshuffle when a
// device goes offline.
// ---------------------------------------------------------------------------

/// Dark + AMOLED ring/legend/tile segments: teal, violet, amber, sky, lime, rose.
const poolSegmentsDark = <Color>[
  Color(0xFF2DD4BF),
  Color(0xFFA78BFA),
  Color(0xFFFBBF24),
  Color(0xFF38BDF8),
  Color(0xFFA3E635),
  Color(0xFFFB7185),
];

/// Light-theme segments (contrast ≥4.5:1 on #FFFFFF).
const poolSegmentsLight = <Color>[
  Color(0xFF0F766E),
  Color(0xFF6D28D9),
  Color(0xFFB45309),
  Color(0xFF0369A1),
  Color(0xFF4D7C0F),
  Color(0xFFBE123C),
];

const poolStatusOnline = Color(0xFF34D399);
const poolStatusOffline = Color(0xFF94A3B8);
const poolStatusJoining = Color(0xFF38BDF8);
const poolStatusDegraded = Color(0xFFFBBF24);
const poolStatusError = Color(0xFFF87171);

const poolStatusOnlineLight = Color(0xFF047857);
const poolStatusOfflineLight = Color(0xFF475569);
const poolStatusJoiningLight = Color(0xFF0369A1);
const poolStatusDegradedLight = Color(0xFFB45309);
const poolStatusErrorLight = Color(0xFFB91C1C);

const _poolRingTrackDark = Color(0xFF222222); // = surfaceContainerHighest
const _poolRingTrackLight = Color(0xFFE4E4E7);

List<Color> poolSegmentsFor(Brightness brightness) =>
    brightness == Brightness.dark ? poolSegmentsDark : poolSegmentsLight;

Color poolRingTrackFor(Brightness brightness) =>
    brightness == Brightness.dark ? _poolRingTrackDark : _poolRingTrackLight;

/// Slot colour: first six slots take the palette directly; later slots wrap
/// with +40% lightness per lap so adjacent segments stay separable.
Color poolSegmentAt(int index, Brightness brightness) {
  final base = poolSegmentsFor(brightness)[index % poolSegmentsDark.length];
  if (index < poolSegmentsDark.length) return base;
  var hsl = HSLColor.fromColor(base);
  for (var i = 0; i <= index ~/ poolSegmentsDark.length - 1; i++) {
    hsl = hsl.withLightness(math.min(1.0, hsl.lightness + 0.4));
  }
  return hsl.toColor();
}

/// Text/fill colour to place *on* a palette fill: dark themes get the bright
/// fills (ink `#111111`), light themes get the deep fills (white).
Color poolOnColor(Color fill, Brightness brightness) =>
    brightness == Brightness.dark ? const Color(0xFF111111) : Colors.white;

/// "Free" half of each segment: segment colour at 0.26 (dark) / 0.20 (light).
double poolFreeAlphaFor(Brightness brightness) =>
    brightness == Brightness.dark ? 0.26 : 0.20;

// ---------------------------------------------------------------------------
// Byte formatting helpers (always delegate to formatBytes — §5 contract).
// ---------------------------------------------------------------------------

/// `formatBytes` output with the `.0` tail stripped, plus a `0 GB` special
/// case so the empty state keeps the same unit as every other state.
/// Examples: `30.0 GB` → `30 GB`, `3.2 GB` → `3.2 GB`, `0` → `0 GB`.
String formatPoolSize(int bytes) {
  if (bytes <= 0) return '0 GB';
  final s = formatBytes(bytes);
  final dot = s.indexOf('.0 ');
  if (dot > 0) return s.replaceRange(dot, dot + 2, '');
  return s;
}

/// Splits `'30 GB'` into `('30', 'GB')` for the two-size hero number.
({String value, String unit}) splitPoolLabel(String formatted) {
  final sp = formatted.indexOf(' ');
  if (sp < 0) return (value: formatted, unit: '');
  return (value: formatted.substring(0, sp), unit: formatted.substring(sp + 1));
}

/// Roboto Mono 500 digits for contributed/used figures (§2) with tabular
/// figures so columns align vertically. Falls back to the platform mono when
/// Roboto Mono is not bundled.
const poolMonoDigits = TextStyle(
  fontFamily: 'Roboto Mono',
  fontFamilyFallback: <String>['monospace'],
  fontWeight: FontWeight.w500,
  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
);

const _tabular = <FontFeature>[FontFeature.tabularFigures()];

// ---------------------------------------------------------------------------
// Painter geometry — §5.
// ---------------------------------------------------------------------------

/// `sweep_i = (quota_i / totalQuota) * (360 - n * gapDeg)` in degrees.
///
/// The `n * gapDeg` gap budget is reserved first so the ring never overruns.
/// Guards: zero/negative quotas contribute 0; a degenerate sweep ≥359° (only
/// reachable with `gapDeg == 0`) is clamped instead of drawing a full-circle
/// arc.
List<double> computePoolSweeps(
  List<double> quotas, {
  required double totalQuota,
  double gapDeg = 4,
}) {
  final n = quotas.length;
  if (n == 0) return const <double>[];
  var sum = 0.0;
  for (final q in quotas) {
    if (q > 0) sum += q;
  }
  final denom = totalQuota > 0 ? totalQuota : sum;
  if (denom <= 0) return List<double>.filled(n, 0);
  final usable = 360.0 - n * gapDeg;
  final out = <double>[];
  for (final q in quotas) {
    var sweep = q <= 0 ? 0.0 : (q / denom) * usable;
    if (sweep < 0) sweep = 0;
    if (sweep > 359) sweep = 359; // never a degenerate full-circle arc
    out.add(sweep);
  }
  return out;
}

/// One ring segment's data.
@immutable
class PoolDonutSegment {
  const PoolDonutSegment({
    required this.quota,
    required this.used,
    required this.color,
    this.isOffline = false,
    this.isJoining = false,
  });

  final int quota;
  final int used;
  final Color color;
  final bool isOffline;
  final bool isJoining;
}

/// Track → per-segment two-tone arcs → error halo.
@immutable
class PoolRingPainter extends CustomPainter {
  const PoolRingPainter({
    required this.segments,
    required this.sweeps,
    required this.gapDeg,
    required this.trackColor,
    required this.freeAlpha,
    required this.haloColor,
    this.sweepProgress = 1,
    this.strokeWidth = 16,
    this.focusIndex,
    this.previousFocusIndex,
    this.focusProgress = 1,
    this.haloProgress = 0,
    this.placeholderRotation,
    this.dashed = false,
  });

  final List<PoolDonutSegment> segments;

  /// Degrees, parallel to [segments] (from [computePoolSweeps]).
  final List<double> sweeps;
  final double gapDeg;
  final Color trackColor;
  final double freeAlpha;
  final Color haloColor;
  final double sweepProgress;
  final double strokeWidth;
  final int? focusIndex;
  final int? previousFocusIndex;
  final double focusProgress;
  final double haloProgress;
  final double? placeholderRotation;
  final bool dashed;

  double _focusAlpha(int i) {
    final t = focusProgress;
    final prev = previousFocusIndex;
    final focus = focusIndex;
    final before = prev == null ? 1.0 : (i == prev ? 1.0 : 0.45);
    final after = focus == null ? 1.0 : (i == focus ? 1.0 : 0.45);
    return before + (after - before) * t;
  }

  double _focusWidth(int i) {
    final t = focusProgress;
    final big = strokeWidth * 1.25; // 16 → 20 (§8 segment focus)
    final prev = previousFocusIndex;
    final focus = focusIndex;
    final before = prev == null ? strokeWidth : (i == prev ? big : strokeWidth);
    final after = focus == null ? strokeWidth : (i == focus ? big : strokeWidth);
    return before + (after - before) * t;
  }

  void _drawDashed(Canvas canvas, Rect rect, double radius) {
    const onLen = 4.0;
    const offLen = 6.0;
    final track = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    final circumference = 2 * math.pi * radius;
    var drawn = 0.0;
    while (drawn < circumference) {
      final sweep =
          math.min(onLen, circumference - drawn) / radius; // radians
      if (sweep > 0) {
        canvas.drawArc(rect, -math.pi / 2 + drawn / radius, sweep, false, track);
      }
      drawn += onLen + offLen;
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxStroke = strokeWidth * 1.25;
    // Reserve outer room so the 2px error halo never clips (§7C).
    final radius = size.shortestSide / 2 - maxStroke / 2 - 4;
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);

    if (dashed) {
      _drawDashed(canvas, rect, radius);
    } else {
      final track = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = trackColor;
      canvas.drawCircle(center, radius, track);
    }

    final gapRad = gapDeg * math.pi / 180;
    var angle = -math.pi / 2; // clockwise from top
    for (var i = 0; i < segments.length && i < sweeps.length; i++) {
      final seg = segments[i];
      final sweepDeg = sweeps[i];
      final rawSweep = sweepDeg * math.pi / 180;
      if (sweepDeg > 0 && sweepProgress > 0) {
        final sweep = rawSweep * sweepProgress;
        if (sweep > 0) {
          final width = _focusWidth(i);
          final dim = _focusAlpha(i);
          final double freeA;
          final double usedA;
          if (seg.isJoining) {
            freeA = 0.12; // placeholder arc (§7D)
            usedA = 0.12;
          } else if (seg.isOffline) {
            freeA = 0.30; // greyscale-readable offline (§3)
            usedA = 0.30;
          } else {
            freeA = freeAlpha;
            usedA = 1.0;
          }
          final freePaint = Paint()
            ..isAntiAlias = true
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeWidth = width
            ..color =
                seg.color.withValues(alpha: (freeA * dim).clamp(0.0, 1.0));
          canvas.drawArc(rect, angle, sweep, false, freePaint);

          final frac = seg.quota <= 0
              ? 0.0
              : (seg.used / seg.quota).clamp(0.0, 1.0);
          final usedSweep = sweep * frac;
          if (usedSweep > 0) {
            final usedPaint = Paint()
              ..isAntiAlias = true
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = width
              ..color =
                  seg.color.withValues(alpha: (usedA * dim).clamp(0.0, 1.0));
            canvas.drawArc(rect, angle, usedSweep, false, usedPaint);
          }

          final rotation = placeholderRotation;
          if (seg.isJoining && rotation != null) {
            final hlSweep = math.min(rawSweep, 60 * math.pi / 180);
            final travel = math.max(rawSweep - hlSweep, 0);
            final hlPaint = Paint()
              ..isAntiAlias = true
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeWidth = width
              ..color = seg.color.withValues(alpha: 0.55 * dim);
            canvas.drawArc(
                rect, angle + travel * rotation, hlSweep, false, hlPaint);
          }
        }
      }
      angle += rawSweep + gapRad;
    }

    if (haloProgress > 0) {
      final haloRadius =
          (size.shortestSide / 2 - 1.5 - haloProgress).clamp(0.0, double.infinity);
      final halo = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * haloProgress
        ..color = haloColor;
      canvas.drawCircle(center, haloRadius, halo);
    }
  }

  @override
  bool shouldRepaint(PoolRingPainter old) =>
      old.segments != segments ||
      old.sweeps != sweeps ||
      old.sweepProgress != sweepProgress ||
      old.strokeWidth != strokeWidth ||
      old.focusIndex != focusIndex ||
      old.previousFocusIndex != previousFocusIndex ||
      old.focusProgress != focusProgress ||
      old.haloProgress != haloProgress ||
      old.placeholderRotation != placeholderRotation ||
      old.dashed != dashed ||
      old.gapDeg != gapDeg ||
      old.trackColor != trackColor ||
      old.freeAlpha != freeAlpha ||
      old.haloColor != haloColor;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// Unified pool capacity ring: one number, many contributors (§5).
///
/// Geometry: `sweep_i = (quota_i / totalQuota) * (360 - n * gapDeg)`, 4° gaps,
/// clockwise from the top, round caps, two-tone segments (free at 0.26 alpha,
/// used overlay at full colour), offline segments at 0.30 alpha.
class PoolDonut extends StatefulWidget {
  const PoolDonut({
    super.key,
    required this.segments,
    required this.centerBytes,
    this.centerSubLine,
    this.centerColor,
    this.totalQuota,
    this.size = 168,
    this.strokeWidth = 16,
    this.gapDeg = 4,
    this.halo = false,
    this.focusedIndex,
    this.dashed = false,
  });

  final List<PoolDonutSegment> segments;

  /// The big number (pooled total, or available capacity when degraded).
  final int centerBytes;

  /// Small line under the number, e.g. `18.6 GB used · 11.4 GB free`.
  final String? centerSubLine;

  /// Recolours the centre to `statusError` when the pool is full (§7C).
  final Color? centerColor;

  /// Denominator for the sweep formula; falls back to the segment sum.
  final int? totalQuota;

  final double size;
  final double strokeWidth;
  final double gapDeg;

  /// Animates the 2px `statusError` halo (quota exceeded).
  final bool halo;

  /// Legend-chip focus: this arc thickens, the rest drop to 0.45 alpha.
  final int? focusedIndex;

  /// First-run empty state: replace the solid track with a 4/6 dashed ring.
  final bool dashed;

  @override
  State<PoolDonut> createState() => _PoolDonutState();
}

class _PoolDonutState extends State<PoolDonut> with TickerProviderStateMixin {
  late final AnimationController _sweepCtrl; // 600ms easeOutCubic ring sweep
  late final AnimationController _countCtrl; // 700ms easeOutExpo count-up
  late final AnimationController _focusCtrl; // 180ms easeOut segment focus
  late final AnimationController _haloCtrl; // 400ms easeOut quota halo
  AnimationController? _placeholderCtrl; // rotating join highlight
  Tween<int>? _countTween;
  int _displayedBytes = 0;
  int? _prevFocus;
  bool _reduce = false;
  bool _started = false;
  String _signature = '';

  static String _sigOf(List<PoolDonutSegment> s) => s
      .map((e) => '${e.quota}:${e.used}:${e.isOffline}:${e.isJoining}')
      .join(',');

  @override
  void initState() {
    super.initState();
    // Never construct an AnimationController with Duration.zero (§8) — the
    // controllers keep real durations and reduced motion skips `forward()`.
    _sweepCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _countCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
    _focusCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
    _haloCtrl =
        AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    for (final c in [_sweepCtrl, _focusCtrl, _haloCtrl]) {
      c.addListener(_tick);
    }
    _countCtrl.addListener(_countTick);
    _signature = _sigOf(widget.segments);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  void _countTick() {
    final tween = _countTween;
    if (tween != null) _displayedBytes = tween.transform(_countCtrl.value);
    _tick();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduce = MediaQuery.of(context).disableAnimations;
    if (!_started) {
      _started = true;
      _play(_sweepCtrl, fromStart: true);
      _updateCount(widget.centerBytes, initial: true);
      _syncHalo();
      _syncPlaceholder();
    }
  }

  void _play(AnimationController c, {bool fromStart = true}) {
    if (_reduce) {
      c.value = 1; // jump straight to the final value
    } else if (fromStart) {
      c.forward(from: 0);
    } else {
      c.forward();
    }
  }

  void _updateCount(int target, {bool initial = false}) {
    if (_reduce || (initial && target == 0)) {
      _displayedBytes = target;
      return;
    }
    if (!initial && _displayedBytes == target) return;
    if (!initial) {
      final delta = (target - _displayedBytes).abs();
      final threshold = (0.005 * target).round(); // re-run only if |Δ| ≥ 0.5%
      if (_displayedBytes != 0 && delta < threshold) {
        _displayedBytes = target; // silent jump, no animation
        return;
      }
    }
    _countTween = Tween<int>(begin: initial ? 0 : _displayedBytes, end: target);
    if (_reduce) {
      _displayedBytes = target;
      return;
    }
    _countCtrl.forward(from: 0);
  }

  void _syncHalo() {
    final target = widget.halo ? 1.0 : 0.0;
    if (_reduce) {
      _haloCtrl.value = target;
    } else if (_haloCtrl.value != target) {
      _haloCtrl.animateTo(target);
    }
  }

  void _syncPlaceholder() {
    final needed = widget.segments.any((s) => s.isJoining);
    if (needed && _placeholderCtrl == null && !_reduce) {
      _placeholderCtrl = AnimationController(
          vsync: this, duration: const Duration(milliseconds: 1200))
        ..repeat();
      _placeholderCtrl!.addListener(_tick);
    } else if (!needed && _placeholderCtrl != null) {
      _placeholderCtrl!.removeListener(_tick);
      _placeholderCtrl!.dispose();
      _placeholderCtrl = null;
    }
  }

  @override
  void didUpdateWidget(PoolDonut old) {
    super.didUpdateWidget(old);
    final sig = _sigOf(widget.segments);
    if (sig != _signature) {
      _signature = sig;
      _play(_sweepCtrl); // whole ring re-balances together (§8)
      _syncPlaceholder();
    }
    if (widget.centerBytes != old.centerBytes) {
      _updateCount(widget.centerBytes);
    }
    if (widget.focusedIndex != old.focusedIndex) {
      _prevFocus = old.focusedIndex;
      _play(_focusCtrl);
    }
    if (widget.halo != old.halo) _syncHalo();
  }

  @override
  void dispose() {
    for (final c in [_sweepCtrl, _focusCtrl, _haloCtrl]) {
      c.removeListener(_tick);
      c.dispose();
    }
    _countCtrl.removeListener(_countTick);
    _countCtrl.dispose();
    _placeholderCtrl?.removeListener(_tick);
    _placeholderCtrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final segments = widget.segments;
    final quotas = [for (final s in segments) s.quota.toDouble()];
    final sum = quotas.fold<double>(0, (a, b) => a + b);
    final denom = (widget.totalQuota ?? 0) > 0
        ? widget.totalQuota!.toDouble()
        : sum;
    final sweeps = computePoolSweeps(quotas,
        totalQuota: denom, gapDeg: widget.gapDeg);
    final totalUsed =
        segments.fold<int>(0, (a, s) => a + s.used);
    final capacity = denom > 0 ? denom.round() : 0;

    final label = splitPoolLabel(formatPoolSize(_displayedBytes));
    final numberStyle = TextStyle(
      fontSize: 40,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.0,
      color: widget.centerColor ?? scheme.onSurface,
      fontFeatures: _tabular, // no jitter while counting up (§2)
      height: 1.1,
    );
    final unitStyle = TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: widget.centerColor ?? scheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );

    final count = segments.length;
    final semanticsLabel =
        'Pooled capacity ${formatPoolSize(capacity)}, ${formatPoolSize(totalUsed)} used, '
        '$count ${count == 1 ? 'contributor' : 'contributors'}';

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Semantics(
        label: semanticsLabel,
        image: true,
        excludeSemantics: true,
        child: Stack(
          alignment: Alignment.center,
          children: [
            RepaintBoundary(
              child: CustomPaint(
                size: Size.square(widget.size),
                painter: PoolRingPainter(
                  segments: segments,
                  sweeps: sweeps,
                  gapDeg: widget.gapDeg,
                  trackColor: poolRingTrackFor(brightness),
                  freeAlpha: poolFreeAlphaFor(brightness),
                  haloColor: brightness == Brightness.dark
                      ? poolStatusError
                      : poolStatusErrorLight,
                  sweepProgress: _sweepCtrl.value,
                  strokeWidth: widget.strokeWidth,
                  focusIndex: widget.focusedIndex,
                  previousFocusIndex: _prevFocus,
                  focusProgress: _focusCtrl.value,
                  haloProgress: _haloCtrl.value,
                  placeholderRotation: _placeholderCtrl?.value,
                  dashed: widget.dashed,
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(label.value, style: numberStyle),
                    const SizedBox(width: 4),
                    Text(label.unit, style: unitStyle),
                  ],
                ),
                Text(
                  'POOLED',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: scheme.primary,
                      ),
                ),
                if (widget.centerSubLine != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.centerSubLine!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.centerColor ?? scheme.onSurfaceVariant,
                          fontFeatures: _tabular,
                        ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
