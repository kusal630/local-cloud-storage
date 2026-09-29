import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/app/theme.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/data/models/audit_entry.dart';
import 'package:localvault/data/models/device.dart';
import 'package:localvault/data/models/storage_status.dart';
import 'package:localvault/data/repositories/audit_repository.dart';
import 'package:localvault/data/repositories/device_repository.dart';
import 'package:localvault/data/repositories/settings_repository.dart';
import 'package:localvault/features/host_dashboard/host_dashboard_screen.dart';
import 'package:localvault/widgets/common.dart';

/// Stands in for the background-isolate host runner: the dashboard only ever
/// touches it through `dynamic`, so the fake just needs the members the screen
/// reads.
class _FakeServer {
  int urlsCalls = 0;
  bool failUrls = false;

  final bool isRunning = true;
  final String scheme = 'https';
  final int port = 8484;
  final bool isSecure = true;
  final String? fingerprint = 'AA:BB:CC:DD:EE';

  Future<List<String>> urls() {
    urlsCalls++;
    if (failUrls) {
      return Future<List<String>>.error(StateError('connection refused'));
    }
    return Future<List<String>>.value(const [
      'https://vault.local:8484',
      'http://192.168.1.40:8484',
    ]);
  }

  Future<String?> lanUrl() async => 'vault.local:8484';

  Future<String> ensurePairingCode(String deviceId) async => 'K7QM-2X';

  Future<void> stop() async {}
}

class _FakeSettings implements SettingsRepository {
  @override
  String get ownerUsername => 'owner';
  @override
  int get trashRetentionDays => 30;
  @override
  int get deviceQuotaBytes => 0;
  @override
  int get shareDefaultExpiryHours => 24;
  @override
  String? get tlsCertPath => null;
  @override
  String? get tlsKeyPath => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('settings.${invocation.memberName}');
}

class _FakeDevices implements DeviceRepository {
  @override
  List<Device> listAll() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('devices.${invocation.memberName}');
}

class _FakeAudit implements AuditRepository {
  @override
  List<AuditEntry> recent({int limit = 50}) => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('audit.${invocation.memberName}');
}

/// Counts `storageStatus()` calls so the test can prove the storage meters do
/// not re-fetch on every dashboard rebuild.
class _FakeVault implements Vault {
  int storageCalls = 0;
  bool failStorage = false;

  @override
  Future<StorageStatus> storageStatus() {
    storageCalls++;
    if (failStorage) {
      return Future<StorageStatus>.error(StateError('disk unavailable'));
    }
    return Future<StorageStatus>.value(const StorageStatus(
      total: 500 * 1024 * 1024 * 1024,
      free: 300 * 1024 * 1024 * 1024,
      used: 200 * 1024 * 1024 * 1024,
      vaultUsage: 100 * 1024 * 1024 * 1024,
      trashUsage: 20 * 1024 * 1024 * 1024,
    ));
  }

  @override
  final SettingsRepository settings = _FakeSettings();

  @override
  final DeviceRepository devices = _FakeDevices();

  @override
  final AuditRepository audit = _FakeAudit();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('vault.${invocation.memberName}');
}

/// Tall viewport so every dashboard card is built (the ListView only mounts
/// what fits on screen).
void _useFullDashboardHeight(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  HostDashboardData data,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [hostStateProvider.overrideWith((ref) => data)],
      child: MaterialApp(
        theme: lightTheme,
        home: const HostDashboardScreen(),
      ),
    ),
  );
  // Let the futures resolve without depending on a settle loop.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
}

void main() {
  testWidgets('dashboard async futures are not re-created on a 10s tick',
      (tester) async {
    _useFullDashboardHeight(tester);
    final server = _FakeServer();
    final vault = _FakeVault();
    await _pumpDashboard(
        tester, HostDashboardData(server: server, vault: vault));

    expect(find.text('https://vault.local:8484'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(server.urlsCalls, 1);
    expect(vault.storageCalls, 1);

    // Three refresh ticks: the synchronous cards rebuild, the async cards
    // must keep their cached futures.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 10));
      await tester.pump(const Duration(milliseconds: 600));
    }

    expect(server.urlsCalls, 1,
        reason: 'the 10s tick must not restart the URL fetch');
    expect(vault.storageCalls, 1,
        reason: 'the 10s tick must not restart the storage fetch');
    expect(find.byType(LoadingIndicator), findsNothing,
        reason: 'an already-rendered card must never fall back to a spinner');
    expect(find.text('https://vault.local:8484'), findsOneWidget);
    expect(find.text('Total'), findsOneWidget);
    expect(tester.widgetList(find.byType(LinearProgressIndicator)).length, 2);
  });

  testWidgets('a failed URL fetch shows a message and a retry, not a spinner',
      (tester) async {
    _useFullDashboardHeight(tester);
    final server = _FakeServer()..failUrls = true;
    final vault = _FakeVault();
    await _pumpDashboard(
        tester, HostDashboardData(server: server, vault: vault));

    expect(find.byType(LoadingIndicator), findsNothing);
    expect(
        find.text("Couldn't load this device's addresses. "
            'Tap Retry to try again.'),
        findsOneWidget);

    server.failUrls = false;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('https://vault.local:8484'), findsOneWidget);
    expect(server.urlsCalls, 2);
  });

  testWidgets('a failed storage fetch explains itself instead of leaking an '
      'exception', (tester) async {
    _useFullDashboardHeight(tester);
    final server = _FakeServer();
    final vault = _FakeVault()..failStorage = true;
    await _pumpDashboard(
        tester, HostDashboardData(server: server, vault: vault));

    expect(find.byType(LoadingIndicator), findsNothing);
    expect(find.textContaining('Error:'), findsNothing);
    expect(
        find.text(
            "Couldn't read this device's storage. Tap Retry to try again."),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
