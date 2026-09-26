import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/features/pool/pool_contributor_tile.dart';
import 'package:localvault/features/pool/pool_models.dart';
import 'package:localvault/features/pool/pool_screen.dart';
import 'package:localvault/widgets/pool_capacity_card.dart';
import 'package:localvault/widgets/pool_donut.dart';

const _gib = 1024 * 1024 * 1024;

PoolContributor _device(
  String id, {
  required String name,
  required int quota,
  int used = 0,
  PoolContributorStatus status = PoolContributorStatus.online,
  bool thisDevice = false,
  String kind = 'phone',
}) {
  return PoolContributor(
    id: id,
    name: name,
    quotaBytes: quota,
    usedBytes: used,
    status: status,
    isThisDevice: thisDevice,
    deviceKind: kind,
  );
}

/// Pumps [screen] with a stubbed loader, lets the snapshot land, then advances
/// past every entry animation (count-up 700ms, ring 600ms, staggers 380ms).
Future<void> _pumpScreen(WidgetTester tester, PoolStatus status) async {
  await tester.pumpWidget(
    MaterialApp(
      home: PoolScreen(fetchStatus: () async => status),
    ),
  );
  await tester.pump(); // resolve the loader future
  await tester.pump(); // rebuild with data
  await tester.pump(const Duration(milliseconds: 1200));
}

/// Unmounts the tree (cancels widget timers) and flushes any haptic
/// `Future.delayed` timers so the fake clock is left clean.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  group('computePoolSweeps (painter geometry, §5)', () {
    test('sweeps are proportional to quota with the gap budget reserved', () {
      // sweep_i = (quota_i / totalQuota) * (360 - n * gapDeg)
      final sweeps =
          computePoolSweeps([30.0, 10.0], totalQuota: 40.0, gapDeg: 4);
      expect(sweeps, hasLength(2));
      expect(sweeps[0], closeTo(0.75 * 352, 1e-9)); // 264°
      expect(sweeps[1], closeTo(0.25 * 352, 1e-9)); // 88°
      expect(sweeps[0] + sweeps[1], closeTo(352, 1e-9)); // 360 - 2*4
    });

    test('three equal contributors split the usable ring evenly', () {
      final sweeps =
          computePoolSweeps([10.0, 10.0, 10.0], totalQuota: 30.0, gapDeg: 4);
      for (final s in sweeps) {
        expect(s, closeTo(348 / 3, 1e-9));
      }
      expect(sweeps.fold<double>(0, (a, b) => a + b), closeTo(348, 1e-9));
    });

    test('total below the sum leaves unattributed ring (denominator is pool total)', () {
      final sweeps = computePoolSweeps([10.0, 10.0], totalQuota: 40.0);
      expect(sweeps[0], closeTo(88, 1e-9));
      expect(sweeps[1], closeTo(88, 1e-9));
      expect(sweeps[0] + sweeps[1], closeTo(176, 1e-9));
    });

    test('guards zero/negative quotas, empty input and degenerate full circle', () {
      expect(computePoolSweeps(const [], totalQuota: 100), isEmpty);
      expect(computePoolSweeps([0.0, 10.0], totalQuota: 10)[0], 0);
      expect(computePoolSweeps([-5.0, 15.0], totalQuota: 10)[0], 0);
      // All-zero quotas → no arc at all.
      expect(
        computePoolSweeps(const [0.0, 0.0], totalQuota: 0),
        [0.0, 0.0],
      );
      // gapDeg 0 + one contributor = 360° → clamped instead of a full circle.
      expect(computePoolSweeps([10.0], totalQuota: 10, gapDeg: 0)[0], 359);
      // Zero pool total falls back to the sum of positive quotas.
      final fallback = computePoolSweeps([10.0, 30.0], totalQuota: 0);
      expect(fallback[0] + fallback[1], closeTo(352, 1e-9));
    });
  });

  group('PoolRingPainter smoke', () {
    PoolRingPainter build({
      List<PoolDonutSegment> segments = const [],
      List<double> sweeps = const [],
      int? focusIndex,
      int? previousFocusIndex,
      double focusProgress = 1,
      double haloProgress = 0,
      double? placeholderRotation,
      bool dashed = false,
    }) {
      return PoolRingPainter(
        segments: segments,
        sweeps: sweeps,
        gapDeg: 4,
        trackColor: const Color(0xFF222222),
        freeAlpha: 0.26,
        haloColor: const Color(0xFFF87171),
        focusIndex: focusIndex,
        previousFocusIndex: previousFocusIndex,
        focusProgress: focusProgress,
        haloProgress: haloProgress,
        placeholderRotation: placeholderRotation,
        dashed: dashed,
      );
    }

    void paint(PoolRingPainter painter) {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(168, 168));
      recorder.endRecording();
    }

    test('paints two-tone segments, offline dimming and error halo', () {
      paint(build(
        segments: [
          PoolDonutSegment(
              quota: 30 * _gib, used: 18 * _gib, color: const Color(0xFF2DD4BF)),
          PoolDonutSegment(
              quota: 10 * _gib,
              used: 4 * _gib,
              color: const Color(0xFFA78BFA),
              isOffline: true),
        ],
        sweeps: [264, 88],
        haloProgress: 1,
      ));
    });

    test('paints dashed empty ring, focused arc and joining placeholder', () {
      paint(build(dashed: true));
      paint(build(
        segments: [
          PoolDonutSegment(
              quota: 10 * _gib, used: _gib, color: const Color(0xFF38BDF8)),
          PoolDonutSegment(
              quota: 10 * _gib,
              used: 0,
              color: const Color(0xFFFBBF24),
              isJoining: true),
        ],
        sweeps: [174, 174],
        focusIndex: 1,
        previousFocusIndex: 0,
        focusProgress: 0.5,
        placeholderRotation: 0.4,
      ));
    });

    test('skips degenerate zero sweeps without throwing', () {
      paint(build(
        segments: [
          PoolDonutSegment(
              quota: 0, used: 0, color: const Color(0xFF38BDF8)),
        ],
        sweeps: [0],
      ));
    });
  });

  group('centre label formatting', () {
    test('formatPoolSize strips .0 tails and normalises zero', () {
      expect(formatPoolSize(0), '0 GB');
      expect(formatPoolSize(30 * _gib), '30 GB');
      expect(formatPoolSize((3.2 * _gib).round()), '3.2 GB');
      expect(formatPoolSize(_gib), '1 GB');
    });

    test('splitPoolLabel separates value and unit', () {
      final r = splitPoolLabel('30 GB');
      expect(r.value, '30');
      expect(r.unit, 'GB');
      final r2 = splitPoolLabel('18.6 GB');
      expect(r2.value, '18.6');
      expect(r2.unit, 'GB');
    });

    testWidgets('PoolDonut renders the hero number, unit and POOLED line',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: PoolDonut(
                segments: [
                  PoolDonutSegment(
                    quota: 30 * (1024 * 1024 * 1024),
                    used: 18 * (1024 * 1024 * 1024),
                    color: Color(0xFF2DD4BF),
                  ),
                ],
                centerBytes: 30 * (1024 * 1024 * 1024),
                centerSubLine: '18 GB used · 12 GB free',
                totalQuota: 30 * (1024 * 1024 * 1024),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // start the count-up
      await tester.pump(const Duration(milliseconds: 800)); // finish it

      expect(find.text('30'), findsOneWidget);
      expect(find.text('GB'), findsOneWidget);
      expect(find.text('POOLED'), findsOneWidget);
      expect(find.text('18 GB used · 12 GB free'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('PoolCapacityCard', () {
    testWidgets('renders header, health pill, stats and legend chips',
        (tester) async {
      final status = PoolStatus(
        totalQuota: 40 * _gib,
        usedBytes: 18 * _gib,
        contributors: [
          _device('a', name: 'Pixel 7', quota: 30 * _gib, used: 15 * _gib,
              thisDevice: true),
          _device('b', name: 'Laptop', quota: 10 * _gib, used: 3 * _gib,
              kind: 'laptop'),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: PoolCapacityCard(status: status))),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      expect(find.text('POOLED CLOUD'), findsOneWidget);
      expect(find.text('Healthy'), findsOneWidget);
      expect(find.text('Contributors'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // contributor count
      expect(find.text('Used'), findsOneWidget);
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('Pixel 7'), findsOneWidget); // legend chip
      expect(find.text('Laptop'), findsOneWidget);
      expect(find.text('30 GB'), findsOneWidget); // mono legend bytes
      await _teardown(tester);
    });

    testWidgets('empty pool swaps the ring for a dashed track plus CTA',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoolCapacityCard(status: PoolStatus.empty()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      expect(find.text('Your cloud has no space yet'), findsOneWidget);
      expect(find.text('Contribute this device'), findsOneWidget);
      expect(find.text('How pooling works'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('PoolScreen states (§7)', () {
    testWidgets('A. empty state renders its copy', (tester) async {
      await _pumpScreen(tester, PoolStatus.empty());

      expect(find.text('Your cloud has no space yet'), findsOneWidget);
      expect(find.text(
              'Contribute free space from this device and add others to pool it into one drive.'),
          findsOneWidget);
      expect(find.text('Contribute this device'), findsOneWidget);
      expect(find.text('How pooling works'), findsOneWidget);
      expect(find.text('Pooled cloud'), findsOneWidget); // AppBar
      await _teardown(tester);
    });

    testWidgets('B. degraded banner shows offline count, bytes and centre switches to available',
        (tester) async {
      final status = PoolStatus(
        totalQuota: 30 * _gib,
        usedBytes: 19 * _gib,
        contributors: [
          _device('a', name: 'Pixel 7', quota: 10 * _gib, used: 10 * _gib),
          _device('b', name: 'Tablet', quota: 11 * _gib, used: 9 * _gib,
              status: PoolContributorStatus.offline, kind: 'tablet'),
          _device('c', name: 'Laptop', quota: 9 * _gib, used: 0,
              kind: 'laptop'),
        ],
      );
      await _pumpScreen(tester, status);

      expect(find.text('1 of 3 devices are offline'), findsOneWidget);
      expect(find.text('11 GB temporarily unavailable'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      expect(find.text('Degraded'), findsOneWidget);
      // Centre number = available capacity (30 - 11), not the total.
      expect(find.text('19'), findsOneWidget);
      expect(find.text('11 GB offline'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget); // offline tile pill
      await _teardown(tester);
    });

    testWidgets('C. quota exceeded renders the error card and Full pill',
        (tester) async {
      final status = PoolStatus(
        totalQuota: 10 * _gib,
        usedBytes: (9.5 * _gib).round(),
        quotaExceeded: true,
        contributors: [
          _device('a', name: 'Pixel 7', quota: 10 * _gib, used: (9.5 * _gib).round()),
        ],
      );
      await _pumpScreen(tester, status);

      expect(
        find.text(
            "The pool is full. Free space, raise a contributor's quota, or add a device before uploads resume."),
        findsOneWidget,
      );
      expect(find.text('Manage space'), findsOneWidget);
      expect(find.text('Full'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('D. joining shows staged text, then collapses to error + Retry after 15s',
        (tester) async {
      final status = PoolStatus(
        totalQuota: 10 * _gib,
        usedBytes: 0,
        contributors: [
          _device('a', name: 'Pixel 7', quota: 10 * _gib),
          _device('b', name: 'Tablet', quota: 10 * _gib,
              status: PoolContributorStatus.joining, kind: 'tablet'),
        ],
      );
      await _pumpScreen(tester, status);

      expect(find.text('Joining'), findsAtLeastNWidgets(1));
      expect(find.text('Verifying pairing…'), findsOneWidget);

      // 15s timeout → tile collapses to statusError + Retry (§7D).
      await tester.pump(const Duration(seconds: 16));
      expect(find.text('Join failed'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('refresh button reloads the snapshot', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: PoolScreen(
            fetchStatus: () async {
              calls++;
              return PoolStatus.empty();
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls, 1);

      await tester.tap(find.byTooltip('Refresh pool'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(calls, 2);
      await _teardown(tester);
    });
  });

  group('PoolContributorTile', () {
    testWidgets('renders gives/uses figures with mono digits and meter',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolContributorTile(
              contributor: _device('a',
                  name: 'Pixel 7',
                  quota: 10 * _gib,
                  used: (3.2 * _gib).round(),
                  thisDevice: true),
              color: const Color(0xFF2DD4BF),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Pixel 7'), findsOneWidget);
      expect(find.text('Gives 10 GB · uses 3.2 GB'), findsOneWidget);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('This device'),
          findsNWidgets(2)); // status pill + meter label row
      expect(find.text('32% of its share'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('revoke opens a confirmation sheet with the consequence copy',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolContributorTile(
              contributor: _device('a',
                  name: 'Pixel 7',
                  quota: 10 * _gib,
                  used: (3.2 * _gib).round()),
              color: const Color(0xFF2DD4BF),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Actions for Pixel 7'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();

      expect(find.text('Revoke Pixel 7?'), findsOneWidget);
      expect(
        find.text(
            'Its 10 GB leaves the pool; 3.2 GB of stored chunks re-replicate.'),
        findsOneWidget,
      );
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Revoke'), findsOneWidget); // destructive confirm
      await _teardown(tester);
    });

    testWidgets('set quota opens a slider sheet, not a dialog', (tester) async {
      var quota = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolContributorTile(
              contributor: _device('a', name: 'Pixel 7', quota: 10 * _gib),
              color: const Color(0xFF2DD4BF),
              onQuotaChanged: (q) => quota = q,
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byTooltip('Actions for Pixel 7'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Set quota…'));
      await tester.pumpAndSettle();

      expect(find.text('Set quota for Pixel 7'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);

      await tester.tap(find.text('Save 10 GB'));
      await tester.pumpAndSettle();
      expect(quota, 10 * _gib);
      expect(find.text('Quota set to 10 GB'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('PoolContributorsCard', () {
    testWidgets('pins this device first and shows every contributor',
        (tester) async {
      final contributors = [
        _device('other', name: 'Laptop', quota: 10 * _gib, kind: 'laptop'),
        _device('me', name: 'Pixel 7', quota: 20 * _gib, thisDevice: true),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoolContributorsCard(contributors: contributors),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.text('CONTRIBUTORS (2)'), findsOneWidget);
      expect(find.text('Add device'), findsOneWidget);
      final names = tester
          .widgetList<Text>(find.textContaining('Pixel 7'))
          .map((t) => t.data)
          .toList();
      expect(names, contains('Pixel 7'));

      // "This device" tile must be above the laptop tile.
      final tileFinders = find.byType(PoolContributorTile);
      expect(tileFinders, findsNWidgets(2));
      final positions = tileFinders.evaluate().map((e) {
        final box = e.renderObject as RenderBox;
        return box.localToGlobal(Offset.zero).dy;
      }).toList();
      expect(positions.first, lessThan(positions.last));
      await _teardown(tester);
    });
  });
}
