import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/auth_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/features/settings/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Logout that always fails — used to prove the failure is surfaced.
class _FailingAuthService extends AuthService {
  _FailingAuthService() : super(LocalVaultApi(session: SessionStore()));

  @override
  Future<void> logout() async => throw Exception('host unreachable');
}

Future<void> _pumpSettings(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(child: MaterialApp(home: SettingsScreen())),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('ignore patterns field keeps in-progress typing across a rebuild',
      (tester) async {
    SharedPreferences.setMockInitialValues({'backup_enabled': false});
    await _pumpSettings(tester);

    final field = find.byType(TextField);
    await tester.scrollUntilVisible(
      field,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(field, '*.tmp, drafts');
    await tester.pump();

    // Toggling a backup switch notifies the provider and rebuilds this
    // section — the old controller was thrown away on every such rebuild.
    final backupSwitch =
        find.widgetWithText(SwitchListTile, 'Backup watched folders');
    await tester.ensureVisible(backupSwitch);
    await tester.pump();
    await tester.tap(backupSwitch);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    await tester.ensureVisible(field);
    await tester.pump();
    expect(find.widgetWithText(TextField, '*.tmp, drafts'), findsOneWidget);
  });

  testWidgets('disconnect reports a failed logout instead of swallowing it',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(_FailingAuthService())],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final disconnect = find.text('Disconnect');
    await tester.scrollUntilVisible(
      disconnect,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(disconnect);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Could not disconnect from the host. Try again.'),
      findsOneWidget,
    );
    // The user stays on Settings so they can retry.
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('theme control shows the current mode and the option set',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await _pumpSettings(tester);

    final themeDropdown = find.byType(DropdownButton<ThemeMode>);
    await tester.ensureVisible(themeDropdown);
    await tester.pump();

    // Current value is visible without opening anything.
    expect(find.text('System'), findsOneWidget);

    await tester.tap(themeDropdown);
    await tester.pumpAndSettle();

    // The full option set is discoverable.
    expect(find.text('Light').hitTestable(), findsOneWidget);
    expect(find.text('Dark').hitTestable(), findsOneWidget);
  });
}
