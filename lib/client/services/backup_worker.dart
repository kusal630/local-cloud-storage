import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import '../session_store.dart';
import 'backup_service.dart';
import 'file_service.dart';
import 'transfer_manager.dart';
import '../api_client.dart';

/// Headless entry point for periodic background backup (Android WorkManager,
/// iOS BGAppRefreshTask). Runs without the UI: reads the saved session,
/// scans watched folders, and uploads new files.
@pragma('vm:entry-point')
void backupCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('backup_enabled') != true) return true;
      if (prefs.getBool('backup_bg_enabled') != true) return true;

      final session = SessionStore();
      if (await session.getRefreshToken() == null) return true;
      final deviceName =
          await session.getDeviceName() ?? 'device';

      final api = LocalVaultApi(session: session);
      final serverUrl = await session.getServerUrl();
      if (serverUrl == null || serverUrl.isEmpty) return true;
      api.configure(serverUrl);

      final files = FileService(api);
      final transfers = TransferManager(files);
      final backup = BackupService(files, transfers);
      await backup.load();
      await backup.runBackup(deviceName: deviceName);

      // Wait for queued uploads (WorkManager caps ~10 min on Android).
      final deadline =
          DateTime.now().add(const Duration(minutes: 9));
      while (DateTime.now().isBefore(deadline)) {
        final pending = transfers.tasks.where((t) =>
            t.status == TransferStatus.queued ||
            t.status == TransferStatus.running);
        if (pending.isEmpty) break;
        await Future<void>.delayed(const Duration(seconds: 5));
      }
      final failed = transfers.tasks
          .where((t) => t.status == TransferStatus.failed)
          .length;
      return failed == 0;
    } catch (_) {
      return false;
    }
  });
}
