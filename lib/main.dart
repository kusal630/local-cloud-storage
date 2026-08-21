import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'core/logging/app_logger.dart' as log;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  log.logInfo('LocalVault starting...');
  runApp(const ProviderScope(child: LocalVaultApp()));
}