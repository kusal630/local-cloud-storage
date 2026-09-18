import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
    await tester.pumpWidget(const ProviderScope(child: LocalVaultApp()));
    await tester.pumpAndSettle();
    expect(find.text('LocalVault'), findsOneWidget);
  });
}