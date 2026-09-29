import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/storage_status.dart';
import 'package:localvault/features/pool/pool_contributor_tile.dart';
import 'package:localvault/features/pool/pool_models.dart';
import 'package:localvault/features/pool/pool_screen.dart';
import 'package:localvault/features/storage/storage_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gib = 1024 * 1024 * 1024;

/// The largest text step Android offers, and the point where a fixed-size
/// hero number either fits inside its ring or spills out of it.
///
/// The scale has to be installed through [MaterialApp.builder]: the app
/// installs its own `MediaQuery` inside, so an outer one is replaced before
/// it ever reaches the subtree under test.
const double _bigText = 2.0;

/// StorageService double — real numbers, nothing else.
class _FakeFileService extends FileService {
  _FakeFileService() : super(LocalVaultApi(session: SessionStore()));

  @override
  Future<StorageStatus> storageStatus() async => StorageStatus(
        total: 1000,
        free: 400,
        used: 600,
        vaultUsage: 300,
        trashUsage: 50,
      );

  @override
  Future<Map<String, int>> storageBreakdown() async => const {};
}

/// A pool with eight devices — enough to exercise both the pinned "This
/// device" row and the folded tail behind it.
PoolStatus _eightDevices() => PoolStatus(
      totalQuota: 30 * _gib,
      usedBytes: 19 * _gib,
      contributors: [
        for (var i = 0; i < 8; i++)
          PoolContributor(
            id: 'd$i',
            name: 'Device $i',
            quotaBytes: (i + 1) * _gib,
            usedBytes: 0,
            status: PoolContributorStatus.online,
            isThisDevice: i == 0,
            deviceKind: 'phone',
          ),
      ],
    );

/// Installs the large-text scale, pumps [child] at it, and returns every
/// layout error the framework caught along the way.
///
/// Exceptions are drained one at a time rather than only the first, because
/// one layout bug usually hides the next behind it. [after] runs before the
/// caller asserts, so a test can scroll to widgets the first viewport never
/// built.
Future<List<Object>> _pumpAtBigText(
  WidgetTester tester,
  Widget child, {
  Future<void> Function(WidgetTester tester)? after,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, route) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(_bigText)),
        child: route!,
      ),
      home: child,
    ),
  );
  // Let entry animations and the hero count-up settle — a number only passes
  // through its widest form mid-tween, so one frame is not a fair sample.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 1600));
  if (after != null) await after(tester);
  return _drainExceptions(tester);
}

/// Everything the framework recorded, so one assertion reports all of them.
List<Object> _drainExceptions(WidgetTester tester) {
  final caught = <Object>[];
  for (var i = 0; i < 50; i++) {
    final e = tester.takeException();
    if (e == null) break;
    caught.add(e);
  }
  return caught;
}

void _expectNoOverflow(List<Object> caught) => expect(
      caught,
      isEmpty,
      reason: 'nothing may clip when text is doubled:\n'
          '${caught.map((e) => e.toString()).join('\n')}',
    );

/// Unmounts so state-owned tickers (the 15s freshness line) are cancelled
/// with the widget rather than left pending at the end of the test.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  SharedPreferences.setMockInitialValues({});

  testWidgets('storage screen fits at 200% text scale', (tester) async {
    // Tall viewport so the entire screen lays out at once — the overflow
    // check is only worth as much as the widgets it actually reaches.
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final caught = await _pumpAtBigText(
      tester,
      ProviderScope(
        overrides: [fileServiceProvider.overrideWithValue(_FakeFileService())],
        child: const StorageScreen(),
      ),
    );

    _expectNoOverflow(caught);
    expect(
      find.textContaining('Updated'),
      findsOneWidget,
      reason: 'the freshness line survives the larger text',
    );
    await _unmount(tester);
  });

  testWidgets('pool screen fits at 200% text scale', (tester) async {
    // Tall viewport so the entire screen lays out at once — the overflow
    // check is only worth as much as the widgets it actually reaches.
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final status = _eightDevices();
    final caught =
        await _pumpAtBigText(tester, PoolScreen(fetchStatus: () async => status));

    _expectNoOverflow(caught);
    expect(
      find.textContaining('Updated'),
      findsOneWidget,
      reason: 'the freshness line survives the larger text',
    );
    await _unmount(tester);
  });

  testWidgets('folded contributor tail fits at 200% text scale',
      (tester) async {
    // Tall viewport: a ListView only mounts the rows that fit on screen, and
    // the point of this test is to lay the whole card out at once.
    tester.view.physicalSize = const Size(900, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final caught = await _pumpAtBigText(
      tester,
      Scaffold(
        body: SingleChildScrollView(
          child: PoolContributorsCard(
            contributors: _eightDevices().contributors,
          ),
        ),
      ),
    );

    _expectNoOverflow(caught);
    expect(find.byType(PoolContributorTile), findsNWidgets(6));
    expect(
      find.text('2 more devices · 5 GB'),
      findsOneWidget,
      reason: '"This device" is pinned, so the two smallest others fold away',
    );
    await _unmount(tester);
  });
}
