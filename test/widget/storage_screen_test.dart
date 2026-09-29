import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/storage_status.dart';
import 'package:localvault/features/pool/contribute_sheet.dart';
import 'package:localvault/features/pool/pool_models.dart';
import 'package:localvault/features/storage/storage_screen.dart';
import 'package:localvault/widgets/pool_capacity_card.dart';
import 'package:localvault/widgets/pool_donut.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app's warning amber for a light theme — the tokens live in
/// `pool_donut.dart`, and every test here pumps the default (light)
/// `MaterialApp`, so the light variant is the one the screen picks.
const _amber = poolStatusDegradedLight;

/// StorageService double: real status numbers, duplicates on demand.
class _FakeStorageService extends FileService {
  _FakeStorageService() : super(LocalVaultApi(session: SessionStore()));

  /// Flip back to false to exercise the retry path.
  bool duplicatesFail = true;

  /// Share of the disk in use — assign before pumping a screen under test.
  double usedFraction = 0.6;

  @override
  Future<StorageStatus> storageStatus() async {
    const total = 1000;
    final used = (total * usedFraction).round();
    return StorageStatus(
      total: total,
      free: total - used,
      used: used,
      vaultUsage: used ~/ 2,
      trashUsage: 50,
    );
  }

  @override
  Future<Map<String, int>> storageBreakdown() async => const {};

  @override
  Future<List<DuplicateGroup>> listDuplicates() async {
    if (duplicatesFail) throw Exception('duplicates unavailable');
    return <DuplicateGroup>[];
  }
}

Future<void> _pumpStorage(WidgetTester tester, _FakeStorageService fake) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [fileServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: StorageScreen()),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// Pump a storage screen at [fraction] of the disk in use.
Future<void> _pumpAt(WidgetTester tester, double fraction) =>
    _pumpStorage(tester, _FakeStorageService()..usedFraction = fraction);

/// An indeterminate spinner — the "still loading" signal. Determinate
/// indicators (the storage donut) do not count.
bool _isSpinning(Widget widget) =>
    widget is CircularProgressIndicator && widget.value == null;

/// Any painted text already in the warning amber.
bool _amberText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .any((t) => t.style?.color == _amber);

/// Any donut ring already painted in the warning amber.
bool _amberRing(WidgetTester tester) =>
    tester.widgetList<CircularProgressIndicator>(find.byType(
      CircularProgressIndicator,
    ))
        .any((c) => c.color == _amber);

/// Colour of the donut's hero number, e.g. `heroNumber(tester, '76%')`.
Color? _heroNumber(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style?.color;

void main() {
  SharedPreferences.setMockInitialValues({});

  testWidgets('duplicate load failure shows an error with retry, not a spinner',
      (tester) async {
    final fake = _FakeStorageService();
    await _pumpStorage(tester, fake);

    final error =
        find.text("Couldn't load the duplicates list. Tap Retry to try again.");
    await tester.scrollUntilVisible(
      error,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(error);
    await tester.pump();

    expect(error, findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byWidgetPredicate(_isSpinning), findsNothing);

    // Recoverable: once the service answers, retry replaces the error.
    fake.duplicatesFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(error, findsNothing);
    expect(
      find.text('No duplicate files — every byte is unique.'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // Graded thresholds — RESEARCH/UX_BENCHMARK.md item 2.
  // -------------------------------------------------------------------------
  group('graded storage thresholds', () {
    testWidgets('50% in use shows no amber and no warning words',
        (tester) async {
      await _pumpAt(tester, 0.5);

      expect(_amberText(tester), isFalse, reason: 'a healthy disk is calm');
      expect(_amberRing(tester), isFalse);
      expect(find.text('Almost full — free up space soon.'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.text('Storage is 50% full.'), findsNothing);
      expect(find.text('Free up space'), findsNothing);
    });

    testWidgets('70% in use — still below the first threshold, no amber',
        (tester) async {
      await _pumpAt(tester, 0.7);

      expect(_amberText(tester), isFalse);
      expect(_amberRing(tester), isFalse);
      expect(_heroNumber(tester, '70%'), isNot(_amber));
      expect(find.text('Almost full — free up space soon.'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('75% warms the hero number and states it in words, ring calm',
        (tester) async {
      await _pumpAt(tester, 0.76);

      expect(_heroNumber(tester, '76%'), _amber,
          reason: 'the number is the first signal');
      expect(_amberRing(tester), isFalse,
          reason: 'the ring only joins at 85%');
      // Words, not hue alone: the band says what the colour means.
      expect(find.text('Storage is 76% full.'), findsOneWidget);
      expect(find.text('Almost full — free up space soon.'), findsNothing);
      // The 90% card is still a cliff — no verbs before it.
      expect(find.text('Free up space'), findsNothing);
    });

    testWidgets('85% turns the ring amber and prints a warning sentence',
        (tester) async {
      await _pumpAt(tester, 0.86);

      expect(_amberRing(tester), isTrue);
      expect(_heroNumber(tester, '86%'), _amber);
      expect(find.text('Almost full — free up space soon.'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.text('Free up space'), findsNothing,
          reason: 'the error card waits for 90%');
    });

    testWidgets('90% keeps the error card and gives it both fixes',
        (tester) async {
      await _pumpAt(tester, 0.95);

      expect(
        find.text(
            'Storage is 95% full. Free space or grow the quota before uploads start failing.'),
        findsOneWidget,
      );

      final free = find.widgetWithText(FilledButton, 'Free up space');
      final quota = find.widgetWithText(TextButton, 'Raise quota');
      expect(free, findsOneWidget);
      expect(quota, findsOneWidget);
      expect(tester.widget<FilledButton>(free).onPressed, isNotNull);
      expect(tester.widget<TextButton>(quota).onPressed, isNotNull);

      // Touch floors (DESIGN §10): the theme holds filled buttons at 48px
      // and text buttons at 44px.
      expect(tester.getSize(free).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(quota).height, greaterThanOrEqualTo(44));

      // At 90% the tier is red, not amber — amber is the 75–90% band, and
      // the words at this level are the card's own copy.
      expect(_amberText(tester), isFalse);
      expect(_amberRing(tester), isFalse);
    });
  });

  // -------------------------------------------------------------------------
  // Item 1 — the storage-full card has to lead with a verb.
  // -------------------------------------------------------------------------
  group('storage-full card actions', () {
    testWidgets('"Free up space" navigates to the Trash screen',
        (tester) async {
      final fake = _FakeStorageService()..usedFraction = 0.95;
      final router = GoRouter(
        initialLocation: '/client/storage',
        routes: [
          GoRoute(
            path: '/client/storage',
            builder: (context, state) => const StorageScreen(),
          ),
          GoRoute(
            path: '/client/trash',
            builder: (context, state) =>
                const Scaffold(body: Text('TRASH SCREEN')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [fileServiceProvider.overrideWithValue(fake)],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Free up space'));
      // Two frames: the route information parses asynchronously, so one pump
      // leaves the old screen in the tree even though the location moved.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('TRASH SCREEN'), findsOneWidget);
    });

    testWidgets('"Raise quota" fails honestly, never with a raw exception',
        (tester) async {
      // The platform cannot answer in a widget test, so the sheet's
      // prerequisites are missing: the user must get cause + next step,
      // never a stack trace or a silent no-op.
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'unavailable');
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(channel, null),
      );

      await _pumpAt(tester, 0.95);
      await tester.tap(find.text('Raise quota'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        find.text(
            'Could not open the quota sheet. Check that your host is reachable, then try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('MissingPluginException'), findsNothing);
      expect(find.textContaining('Exception('), findsNothing);
      // The sheet never opened — its prerequisites were missing, and the
      // screen said so instead of failing silently.
      expect(find.byType(ContributeSheet), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // Item 2 on the pool hero card — same grading, same words.
  // -------------------------------------------------------------------------
  group('pool capacity card thresholds', () {
    Future<void> pumpCard(WidgetTester tester, double fraction) async {
      const total = 100000000000; // 100 GB
      final used = (total * fraction).round();
      final status = PoolStatus(
        totalQuota: total,
        usedBytes: used,
        contributors: [
          PoolContributor(
            id: 'a',
            name: 'Pixel 7',
            quotaBytes: total,
            usedBytes: used,
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PoolCapacityCard(status: status),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Any container wearing the graded outline.
    bool hasOutline(WidgetTester tester) =>
        tester.widgetList<Container>(find.byType(Container)).any((c) {
          final d = c.decoration;
          return d is BoxDecoration && d.border?.top.color == _amber;
        });

    testWidgets('50% used — no amber, no warning words', (tester) async {
      await pumpCard(tester, 0.5);

      expect(_amberText(tester), isFalse);
      expect(hasOutline(tester), isFalse);
      expect(find.text('Almost full — free up space soon.'), findsNothing);
      expect(find.text('The pool is 50% full.'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('76% used — amber number and a sentence, no outline yet',
        (tester) async {
      await pumpCard(tester, 0.76);

      expect(_amberText(tester), isTrue,
          reason: 'the hero number is the first signal');
      expect(find.text('The pool is 76% full.'), findsOneWidget);
      expect(hasOutline(tester), isFalse,
          reason: 'the ring only joins at 85%');
      expect(find.text('Almost full — free up space soon.'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    });

    testWidgets('86% used — amber outline plus the warning sentence',
        (tester) async {
      await pumpCard(tester, 0.86);

      expect(hasOutline(tester), isTrue);
      expect(_amberText(tester), isTrue);
      expect(find.text('Almost full — free up space soon.'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });
  });

  group('freshness line (item 9)', () {
    testWidgets('says how old the hero numbers are', (tester) async {
      await _pumpAt(tester, 0.6);

      expect(
        find.text('Updated just now'),
        findsOneWidget,
        reason: 'a storage tab left open has to be able to age its numbers',
      );

      // Unmount so the 15s freshness ticker is cancelled with the State.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}
