import 'dart:io';

import 'package:flutter/services.dart';

/// Controls the Android foreground service that keeps the host server alive
/// in the background. No-ops on all other platforms.
abstract class HostServiceControl {
  static const _channel =
      MethodChannel('dev.localvault.localvault/host');

  /// Starts the foreground service (ongoing notification + wake lock).
  static Future<void> start({required String label, required int port}) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startHost', {
        'label': label,
        'port': port,
      });
    } on MissingPluginException catch (_) {
      // Tests / non-Android embedders: nothing to control.
    } on PlatformException catch (_) {
      // Best-effort: the server still runs while the app is foreground.
    }
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopHost');
    } on MissingPluginException catch (_) {
      // Tests / non-Android embedders.
    } on PlatformException catch (_) {
      // Best-effort stop.
    }
  }
}
