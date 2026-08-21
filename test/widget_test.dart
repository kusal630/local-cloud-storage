import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/app.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: LocalVaultApp()));
    await tester.pumpAndSettle();
    expect(find.text('LocalVault'), findsOneWidget);
  });
}