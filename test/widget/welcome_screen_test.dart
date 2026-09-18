import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/features/welcome/welcome_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('Welcome screen shows app name and two buttons', (tester) async {
    SharedPreferences.setMockInitialValues({'onboarding_seen_v1': true});
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: WelcomeScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('LocalVault'), findsOneWidget);
    expect(find.textContaining('Your private local cloud'), findsOneWidget);
    expect(find.text('Start Storage Node'), findsOneWidget);
    expect(find.text('Connect to Storage Node'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });
}