import 'dart:io';

import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../core/logging/app_logger.dart' as log;
import '../data/datasources/vault.dart';
import '../server/host_runner.dart';

/// Headless / kiosk auto-setup for machines like a Raspberry Pi.
///
/// Bake values in at build time:
/// `--dart-define=LOCALVAULT_STORAGE=/mnt/cloud
///  --dart-define=LOCALVAULT_USER=owner
///  --dart-define=LOCALVAULT_PASS=... [--dart-define=LOCALVAULT_NAME=Pi]`
///
/// On start the vault is created on first run (or opened), the node starts,
/// and the dashboard opens already running. Nothing is done unless
/// LOCALVAULT_STORAGE is set.
Future<HostDashboardData?> maybeAutoSetup() async {
  const storage =
      String.fromEnvironment('LOCALVAULT_STORAGE', defaultValue: '');
  if (storage.isEmpty) return null;
  const username =
      String.fromEnvironment('LOCALVAULT_USER', defaultValue: 'owner');
  const password = String.fromEnvironment('LOCALVAULT_PASS');
  const name =
      String.fromEnvironment('LOCALVAULT_NAME', defaultValue: 'Pi Node');
  if (password.isEmpty) {
    log.logWarn('LOCALVAULT_STORAGE set but LOCALVAULT_PASS is empty.');
    return null;
  }
  try {
    final dir = Directory(storage);
    await dir.create(recursive: true);
    if (!Directory(p.join(dir.path, '.localvault')).existsSync()) {
      final created = await Vault.create(dir);
      await created.completeSetup(
          password: password, deviceName: name, username: username);
      created.close();
      log.logInfo('Auto-setup complete for "$name".');
    }
    final runner = await HostRunner.start(storagePath: dir.path);
    return HostDashboardData(server: runner, vault: runner.vault);
  } catch (e, st) {
    log.logError('Auto-setup failed', e, st);
    return null;
  }
}
