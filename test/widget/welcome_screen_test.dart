import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/features/welcome/welcome_screen.dart';

void main() {
  testWidgets('Welcome screen shows app name and two buttons', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: WelcomeScreen()),
      ),
    );

    expect(find.text('LocalVault'), findsOneWidget);
    expect(find.text('Your private local cloud storage'), findsOneWidget);
    expect(find.text('Start Storage Node'), findsOneWidget);
    expect(find.text('Connect to Storage Node'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });
}