import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/features/pool/contribute_sheet.dart';
import 'package:localvault/features/pool/pool_health_banner.dart';
import 'package:localvault/features/pool/pool_models.dart';
import 'package:localvault/features/pool/pool_screen.dart';
import 'package:localvault/widgets/pool_capacity_card.dart';

const _gib = 1024 * 1024 * 1024;

PoolContributor _device(
  String id, {
  required String name,
  required int quota,
  int used = 0,
  PoolContributorStatus status = PoolContributorStatus.online,
  bool thisDevice = false,
  String kind = 'phone',
  DateTime? lastSeen,
}) {
  return PoolContributor(
    id: id,
    name: name,
    quotaBytes: quota,
    usedBytes: used,
    status: status,
    isThisDevice: thisDevice,
    deviceKind: kind,
    lastSeen: lastSeen,
  );
}

/// Pumps [screen] with a stubbed loader, lets the snapshot land, then advances
/// past every entry animation (count-up 700ms, ring 600ms, staggers 380ms).
Future<void> _pumpScreen(WidgetTester tester, PoolStatus status) async {
  await tester.pumpWidget(
    MaterialApp(home: PoolScreen(fetchStatus: () async => status)),
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

Future<void> _openSheet(WidgetTester tester, ContributeSheetArgs args) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              key: const Key('openSheet'),
              onPressed: () => showContributeSheet(context, args: args),
              child: const Text('Open sheet'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('openSheet')));
  await tester.pumpAndSettle();
}

void main() {
  group('PoolScreen — all four §7 states render', () {
    testWidgets('A. empty pool', (tester) async {
      await _pumpScreen(tester, PoolStatus.empty());

      expect(find.text('Your cloud has no space yet'), findsOneWidget);
      expect(find.text('Contribute this device'), findsOneWidget);
      expect(find.text('Empty'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('B. degraded pool', (tester) async {
      await _pumpScreen(
        tester,
        PoolStatus(
          totalQuota: 30 * _gib,
          usedBytes: 19 * _gib,
          contributors: [
            _device('a', name: 'Pixel 7', quota: 10 * _gib, used: 10 * _gib),
            _device(
              'b',
              name: 'Tablet',
              quota: 11 * _gib,
              used: 9 * _gib,
              status: PoolContributorStatus.offline,
              kind: 'tablet',
            ),
            _device('c', name: 'Laptop', quota: 9 * _gib, kind: 'laptop'),
          ],
        ),
      );

      expect(find.text('1 of 3 devices are offline'), findsOneWidget);
      expect(find.text('11 GB temporarily unavailable'), findsOneWidget);
      expect(find.text('Degraded'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('C. quota exceeded', (tester) async {
      await _pumpScreen(
        tester,
        PoolStatus(
          totalQuota: 10 * _gib,
          usedBytes: (9.5 * _gib).round(),
          quotaExceeded: true,
          contributors: [
            _device(
              'a',
              name: 'Pixel 7',
              quota: 10 * _gib,
              used: (9.5 * _gib).round(),
            ),
          ],
        ),
      );

      expect(
        find.text(
          "The pool is full. Free space, raise a contributor's quota, or add a device before uploads resume.",
        ),
        findsOneWidget,
      );
      expect(find.text('Full'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('D. joining in progress', (tester) async {
      await _pumpScreen(
        tester,
        PoolStatus(
          totalQuota: 20 * _gib,
          usedBytes: 0,
          contributors: [
            _device('a', name: 'Pixel 7', quota: 10 * _gib),
            _device(
              'b',
              name: 'Tablet',
              quota: 10 * _gib,
              status: PoolContributorStatus.joining,
              kind: 'tablet',
            ),
          ],
        ),
      );

      expect(find.text('Joining'), findsAtLeastNWidgets(1));
      expect(find.text('Verifying pairing…'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('PoolHealthBanner — ZFS headline state', () {
    Future<void> pumpBanner(
      WidgetTester tester,
      PoolHealthBanner banner, {
      bool reducedMotion = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: reducedMotion),
                child: banner,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('ONLINE shows the green headline word', (tester) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.online,
          totalDevices: 3,
          pooledBytes: 30 * _gib,
        ),
      );

      expect(find.text('ONLINE'), findsOneWidget);
      expect(find.text('3 devices are online'), findsOneWidget);
      expect(find.text('30 GB pooled'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline_rounded), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('DEGRADED names the devices and the bytes at risk', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.degraded,
          totalDevices: 3,
          offlineDevices: 2,
          offlineBytes: 11 * _gib,
          onReview: _noop,
        ),
      );

      expect(find.text('DEGRADED'), findsOneWidget);
      expect(find.text('2 of 3 devices are offline'), findsOneWidget);
      expect(find.text('11 GB temporarily unavailable'), findsOneWidget);
      expect(find.byIcon(Icons.wifi_off_rounded), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('AT RISK states the lost redundancy in files, not a hue', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.atRisk,
          totalDevices: 3,
          atRiskFiles: 14,
        ),
      );

      expect(find.text('AT RISK'), findsOneWidget);
      expect(find.text('No redundancy: 1 copy of 14 files'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('OFFLINE explains that nothing can be read or written', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(health: PoolHealth.offline, totalDevices: 3),
      );

      expect(find.text('OFFLINE'), findsOneWidget);
      expect(find.text('All 3 devices are offline'), findsOneWidget);
      expect(
        find.text(
          'Nothing can be read or written until a device '
          'reconnects.',
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('resilver row shows count, ETA and a determinate bar', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.degraded,
          totalDevices: 3,
          offlineDevices: 1,
          offlineBytes: 10 * _gib,
          repairDone: 3,
          repairTotal: 12,
          repairEta: Duration(seconds: 150),
        ),
      );

      expect(find.text('Repairing 3 of 12 replicas…'), findsOneWidget);
      expect(find.text('about 2m 30s left'), findsOneWidget);
      expect(find.text('25% of replicas rebuilt'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const ValueKey<String>('repairProgress')),
      );
      expect(bar.value, closeTo(0.25, 1e-9));
      await _teardown(tester);
    });

    testWidgets('state change is announced to assistive tech once', (
      tester,
    ) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.accessibility.name,
        (ByteData? message) async {
          final decoded = SystemChannels.accessibility.codec.decodeMessage(
            message,
          );
          if (decoded is Map && decoded['type'] == 'announce') {
            final data = decoded['data'];
            if (data is Map && data['message'] is String) {
              announcements.add(data['message'] as String);
            }
          }
          return null;
        },
      );

      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.online,
          totalDevices: 3,
          pooledBytes: 30 * _gib,
        ),
      );
      expect(announcements, isEmpty); // healthy first paint stays quiet

      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.degraded,
          totalDevices: 3,
          offlineDevices: 1,
          offlineBytes: 10 * _gib,
        ),
      );
      expect(announcements, hasLength(1));
      expect(announcements.single, contains('DEGRADED'));
      expect(announcements.single, contains('1 of 3 devices are offline'));

      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.accessibility.name,
        null,
      );
      await _teardown(tester);
    });

    testWidgets('reduced motion collapses the entry animation to zero', (
      tester,
    ) async {
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.degraded,
          totalDevices: 3,
          offlineDevices: 2,
          offlineBytes: 11 * _gib,
        ),
        reducedMotion: true,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('DEGRADED'), findsOneWidget);

      // A second state entry must not build a controller with duration 0 or
      // leave a ticker running.
      await pumpBanner(
        tester,
        const PoolHealthBanner(
          health: PoolHealth.atRisk,
          totalDevices: 3,
          atRiskFiles: 14,
        ),
        reducedMotion: true,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('AT RISK'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('Contribute sheet', () {
    testWidgets('shows the projection and the next milestone (goal gradient)', (
      tester,
    ) async {
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 30 * _gib,
          thisDeviceFreeBytes: 4 * _gib,
          isContributing: false,
          thisDeviceQuotaBytes: 0,
          onContribute: (_) async {},
          onStop: () async {},
        ),
      );

      expect(find.text('Contribute this device'), findsOneWidget);
      // current → projected (the slider opens on the device's real maximum
      // when 10 GB does not fit, and never offers space that is not there).
      expect(find.text('30 GB'), findsOneWidget);
      expect(find.text('34 GB'), findsOneWidget);
      expect(
        find.text('pool becomes 34 GB when you contribute 4 GB'),
        findsOneWidget,
      );
      // Exactly the next milestone: 40 - 34 = 6.
      expect(
        find.text('6 GB more unlocks 2-device redundancy'),
        findsOneWidget,
      );

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.min, 1 * _gib);
      expect(slider.max, 4 * _gib);
      expect(slider.divisions, 3); // whole 1 GB steps
      await _teardown(tester);
    });

    testWidgets('reports the selected quota and confirms the new total', (
      tester,
    ) async {
      var reported = 0;
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 30 * _gib,
          thisDeviceFreeBytes: 64 * _gib,
          isContributing: false,
          thisDeviceQuotaBytes: 0,
          onContribute: (quota) async => reported = quota,
          onStop: () async {},
        ),
      );

      expect(
        find.text('pool becomes 40 GB when you contribute 10 GB'),
        findsOneWidget,
      );
      expect(find.text('2-device redundancy on'), findsNothing);

      // Preset chip (Hick's law: three options, one decision).
      await tester.tap(find.text('25 GB'));
      await tester.pumpAndSettle();
      expect(
        find.text('pool becomes 55 GB when you contribute 25 GB'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('contributeSubmit')));
      await tester.pumpAndSettle();

      expect(reported, 25 * _gib);
      expect(find.text('Contribute this device'), findsNothing); // closed
      // Peak–end: the flow ends on a confirmation naming the new total.
      expect(find.text('25 GB added · the pool is now 55 GB'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('privacy explainer states what this device can see', (
      tester,
    ) async {
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 30 * _gib,
          thisDeviceFreeBytes: 64 * _gib,
          isContributing: false,
          thisDeviceQuotaBytes: 0,
          onContribute: (_) async {},
          onStop: () async {},
        ),
      );

      expect(
        find.text(
          'Files are split into AES-256-GCM encrypted chunks before '
          'they leave this device.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'This device sees opaque chunk ids only — never file names '
          'or contents.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Capped at 10 GB and revocable at any time: you stay in '
          'control of the share.',
        ),
        findsOneWidget,
      );
      expect(find.text('How pooling works'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('callback errors name the fix and offer Retry', (tester) async {
      var calls = 0;
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 30 * _gib,
          thisDeviceFreeBytes: 64 * _gib,
          isContributing: false,
          thisDeviceQuotaBytes: 0,
          onContribute: (_) async {
            calls++;
            if (calls == 1) throw Exception('host unreachable');
          },
          onStop: () async {},
        ),
      );

      await tester.tap(find.byKey(const Key('contributeSubmit')));
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.byKey(const Key('retryAction')), findsOneWidget);
      expect(
        find.textContaining('on the same network as the host, then retry'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('retryAction')));
      await tester.pumpAndSettle();

      expect(calls, 2);
      expect(find.text('Contribute this device'), findsNothing);
      await _teardown(tester);
    });

    testWidgets('already contributing: share row + consequential stop', (
      tester,
    ) async {
      var stopped = false;
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 40 * _gib,
          thisDeviceFreeBytes: 64 * _gib,
          isContributing: true,
          thisDeviceQuotaBytes: 10 * _gib,
          thisDeviceUsedBytes: (3.2 * _gib).round(),
          thisDeviceSlotIndex: 0,
          onContribute: (_) async {},
          onStop: () async => stopped = true,
        ),
      );

      expect(find.text('Gives 10 GB · uses 3.2 GB'), findsOneWidget);
      expect(find.text('32% of its share'), findsOneWidget);
      expect(find.text('Save 10 GB'), findsOneWidget);
      expect(
        find.text('pool becomes 40 GB — this device already gives 10 GB'),
        findsOneWidget,
      );

      final stop = find.byKey(const Key('stopContribute'));
      await tester.ensureVisible(stop);
      await tester.pumpAndSettle();
      await tester.tap(stop);
      await tester.pumpAndSettle();

      expect(find.text('Stop contributing?'), findsOneWidget);
      expect(
        find.text(
          'Its 10 GB leaves the pool; stored chunks re-replicate to '
          'your other devices first.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'The pool drops to 30 GB and uploads keep working '
          'while chunks are copied across. Nothing is deleted.',
        ),
        findsOneWidget,
      );

      expect(stopped, isFalse); // consequence must be confirmed first
      await tester.tap(find.byKey(const Key('confirmStop')));
      await tester.pumpAndSettle();

      expect(stopped, isTrue);
      expect(find.text('Stop contributing?'), findsNothing); // sheets closed
      await _teardown(tester);
    });
  });

  group('PoolCapacityCard — reserved bytes', () {
    testWidgets('shown as a sub-line while a write is in flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolCapacityCard(
              status: PoolStatus(
                totalQuota: 30 * _gib,
                usedBytes: 12 * _gib,
                reservedBytes: 2 * _gib,
                contributors: [
                  _device('a', name: 'Pixel 7', quota: 10 * _gib, used: 4 * _gib),
                  _device('b', name: 'Laptop', quota: 20 * _gib, kind: 'laptop'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('2 GB reserved'), findsOneWidget);
      // It must not become a fourth stat (§5 fixes the row at three, §11
      // forbids a new KPI card).
      expect(find.text('Reserved'), findsNothing);
      // The figure is never bare: the meaning rides in a tooltip (§10).
      expect(
        find.byTooltip('Claimed by an upload that has not finished yet. It '
            'becomes used when the write commits, or free again if it fails.'),
        findsOneWidget,
      );
      // The three hero stats are still there.
      expect(find.text('Contributors'), findsOneWidget);
      expect(find.text('Used'), findsOneWidget);
      expect(find.text('Free'), findsOneWidget);
      await _teardown(tester);
    });

    testWidgets('nothing extra renders when nothing is in flight', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolCapacityCard(
              status: PoolStatus(
                totalQuota: 30 * _gib,
                usedBytes: 12 * _gib,
                contributors: [
                  _device('a', name: 'Pixel 7', quota: 10 * _gib, used: 4 * _gib),
                  _device('b', name: 'Laptop', quota: 20 * _gib, kind: 'laptop'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.textContaining('reserved'), findsNothing);
      expect(find.byIcon(Icons.schedule_rounded), findsNothing);
      expect(find.text('Free'), findsOneWidget);
      await _teardown(tester);
    });
  });

  group('PoolDonut — count-up', () {
    testWidgets('a frame in the middle of the tween does not throw', (
      tester,
    ) async {
      // Regression: `_countTween` was a `Tween<int>`, whose `lerp` returns a
      // double for an int begin/end — so every frame strictly between 0 and 1
      // threw. `Tween.transform` short-circuits at both endpoints, so a test
      // that only pumped past the 700 ms duration never caught it.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PoolCapacityCard(
              status: PoolStatus(
                totalQuota: 30 * _gib,
                usedBytes: 12 * _gib,
                contributors: [
                  _device('a', name: 'Pixel 7', quota: 10 * _gib, used: 4 * _gib),
                  _device('b', name: 'Laptop', quota: 20 * _gib, kind: 'laptop'),
                ],
              ),
            ),
          ),
        ),
      );

      for (final step in const [100, 150, 150, 150, 150, 300]) {
        await tester.pump(Duration(milliseconds: step));
        expect(tester.takeException(), isNull,
            reason: 'the count-up threw after +${step}ms');
      }
      await _teardown(tester);
    });
  });

  group('Accessibility smoke', () {
    testWidgets('every icon-only control on the pool screen has a tooltip', (
      tester,
    ) async {
      await _pumpScreen(
        tester,
        PoolStatus(
          totalQuota: 30 * _gib,
          usedBytes: 12 * _gib,
          contributors: [
            _device(
              'a',
              name: 'Pixel 7',
              quota: 10 * _gib,
              used: 6 * _gib,
              thisDevice: true,
            ),
            _device('b', name: 'Laptop', quota: 20 * _gib, kind: 'laptop'),
          ],
        ),
      );

      final iconOnly = tester
          .widgetList<Widget>(
            find.byWidgetPredicate(
              (w) => w is IconButton || w is PopupMenuButton,
            ),
          )
          .toList();
      expect(iconOnly, isNotEmpty);
      for (final widget in iconOnly) {
        final tooltip = widget is IconButton
            ? widget.tooltip
            : (widget as PopupMenuButton).tooltip;
        expect(tooltip, isNotNull, reason: '$widget has no tooltip');
        expect(tooltip, isNotEmpty, reason: '$widget has an empty tooltip');
      }
      await _teardown(tester);
    });

    testWidgets('sheet and legend expose labels, never icon-only controls', (
      tester,
    ) async {
      await _openSheet(
        tester,
        ContributeSheetArgs(
          currentPoolBytes: 30 * _gib,
          thisDeviceFreeBytes: 64 * _gib,
          isContributing: false,
          thisDeviceQuotaBytes: 0,
          onContribute: (_) async {},
          onStop: () async {},
        ),
      );

      final iconOnly = tester.widgetList<IconButton>(find.byType(IconButton));
      for (final button in iconOnly) {
        expect(button.tooltip, isNotNull);
      }
      // Chips and the slider carry their own semantics (selected / value).
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.widgetList<Semantics>(find.byType(Semantics)), isNotEmpty);
      await _teardown(tester);
    });
  });
}

void _noop() {}
