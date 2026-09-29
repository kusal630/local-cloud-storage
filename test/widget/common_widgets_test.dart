import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/widgets/common.dart';

/// Unmounts the tree (cancels widget timers, stops shimmer tickers) and
/// flushes any haptic `Future.delayed` timers so the fake clock is left
/// clean — same house pattern as `test/widget/pool_ui_test.dart`.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// Pumps [child] with `disableAnimations` forced on or off, independent of
/// whatever the test binding reports, so the shimmer gate is deterministic.
Widget _motionHost({required bool animations, required Widget child}) {
  return Builder(
    builder: (context) => MaterialApp(
      home: MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: !animations),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('EmptyState widget shows icon and title', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            icon: Icons.folder_open,
            title: 'No files yet',
            subtitle: 'Upload some files',
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.text('No files yet'), findsOneWidget);
    expect(find.text('Upload some files'), findsOneWidget);
  });

  testWidgets('ErrorState widget shows message and retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorState(
            message: 'Something went wrong',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
    await _teardown(tester);
  });

  testWidgets('ErrorState hides the technical details until asked',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ErrorState(
            message: 'Could not reach your host.',
            details: 'DioException [connection timeout] GET /api/v1/trash',
          ),
        ),
      ),
    );

    // The raw exception never appears in the primary read…
    expect(find.text('Could not reach your host.'), findsOneWidget);
    expect(find.textContaining('connection timeout'), findsNothing);
    expect(find.text('Technical details'), findsOneWidget);

    // …and is one tap away, collapsed by default.
    await tester.tap(find.text('Technical details'));
    await tester.pump();
    expect(find.textContaining('connection timeout'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    // The disclosure toggles back shut.
    await tester.tap(find.text('Technical details'));
    await tester.pump();
    expect(find.textContaining('connection timeout'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    await _teardown(tester);
  });

  testWidgets('ErrorState renders and fires a secondary action',
      (tester) async {
    var secondary = 0;
    var retried = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorState(
            message: 'Could not reach your host.',
            onRetry: () => retried++,
            secondaryLabel: 'Open help',
            onSecondary: () => secondary++,
          ),
        ),
      ),
    );

    final outlined = find.byType(OutlinedButton);
    expect(outlined, findsOneWidget);
    expect(find.text('Open help'), findsOneWidget);
    // The primary action is still there, and the pair reflows rather than
    // overflowing when the font is wide.
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Open help'));
    expect(secondary, 1);
    expect(retried, 0);

    await tester.tap(find.text('Retry'));
    expect(retried, 1);
    expect(secondary, 1);
    await _teardown(tester);
  });

  testWidgets('StorageDonut keeps its screen-reader status wrapper',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: StorageDonut(
            fraction: 0.62,
            usedLabel: '18.6 GB used',
            freeLabel: '11.4 GB free',
          ),
        ),
      ),
    );
    await tester.pump();

    final semantics = tester.widgetList<Semantics>(find.byType(Semantics)).where(
          (s) => s.properties.label == 'Storage in use',
        );
    expect(semantics, hasLength(1),
        reason: 'the custom-painted ring must stay announced');
    final wrapper = semantics.single;
    expect(wrapper.properties.role, SemanticsRole.status);
    expect(wrapper.excludeSemantics, isTrue);
    await _teardown(tester);
  });

  testWidgets('SkeletonList shimmer is gated on reduced motion',
      (tester) async {
    await tester.pumpWidget(
      _motionHost(animations: true, child: const SkeletonList()),
    );
    await tester.pump();
    expect(find.byType(Animate), findsWidgets,
        reason: 'with animations on, the rows shimmer');

    await tester.pumpWidget(
      _motionHost(animations: false, child: const SkeletonList()),
    );
    await tester.pump();
    expect(find.byType(Animate), findsNothing,
        reason: 'with animations off, the rows stay still (NN/g, DESIGN §8)');
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  test('formatBytes returns correct strings', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
  });
}
