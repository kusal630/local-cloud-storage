import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'app/auto_setup.dart';
import 'app/providers.dart';
import 'core/logging/app_logger.dart' as log;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  log.logInfo('LocalVault starting...');
  final overrides = <Override>[];
  try {
    final auto = await maybeAutoSetup();
    if (auto != null) {
      overrides.add(hostStateProvider.overrideWith((ref) => auto));
    }
  } catch (e) {
    log.logWarn('Auto-setup skipped: $e');
  }
  runApp(ProviderScope(overrides: overrides, child: const LocalVaultApp()));
}
