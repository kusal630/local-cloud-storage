// The failing preferences store below extends the platform interface that
// SharedPreferences itself swaps in for `setMockInitialValues`. Adding that
// package to pubspec.yaml is outside this change's file ownership, so the
// `depend_on_referenced_packages` lint is suppressed for this test only.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/features/privacy/privacy_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// In-memory store whose writes fail, but whose reads succeed.
class _ClearFailingStore extends InMemorySharedPreferencesStore {
  // Super parameters only bind to an unnamed super constructor.
  // ignore: use_super_parameters
  _ClearFailingStore(Map<String, Object> data) : super.withData(data);

  @override
  Future<bool> remove(String key) async => throw PlatformException(
      code: 'write_failed', message: 'storage unavailable');
}

Future<void> _pumpPrivacy(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: PrivacyScreen())),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('search history load failure is reported honestly',
      (tester) async {
    // A non-list value makes SharedPreferences.getStringList throw, which is
    // exactly the "could not read" case the screen must not paper over.
    SharedPreferences.setMockInitialValues({'search_history': 42});
    await _pumpPrivacy(tester);

    expect(find.text('Could not load search history.'), findsOneWidget);
    expect(find.text('0 recent queries on this device'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('clearing search history reports a failure', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'search_history': <String>['cats', 'dogs']});
    SharedPreferencesStorePlatform.instance = _ClearFailingStore(
        {'flutter.search_history': <String>['cats', 'dogs']});
    await _pumpPrivacy(tester);

    expect(find.text('2 recent queries on this device'), findsOneWidget);

    // The first Clear button belongs to Search history; Transfer history's
    // is disabled (0 entries) but is also present in the tree.
    final clearSearch = find.widgetWithText(TextButton, 'Clear').first;
    await tester.ensureVisible(clearSearch);
    await tester.pump();
    await tester.tap(clearSearch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Could not clear search history.'),
      findsOneWidget,
    );
    // Nothing was cleared, so the count is unchanged.
    expect(find.text('2 recent queries on this device'), findsOneWidget);
  });

  testWidgets('counts use real plurals', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'search_history': <String>['cats']});
    await _pumpPrivacy(tester);

    expect(find.text('1 recent query on this device'), findsOneWidget);
    expect(find.text('0 entries on this device'), findsOneWidget);
  });
}
