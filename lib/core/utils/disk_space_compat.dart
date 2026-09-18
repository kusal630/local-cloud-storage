import 'package:flutter/services.dart';

/// Replacement for the unmaintained `disk_space` plugin (whose Android build
/// uses the long-removed `jcenter()`, breaking release builds).
///
/// Backed by a MethodChannel served from MainActivity (StatFs) on Android.
/// Other platforms return null — callers must treat null as "unavailable".
abstract class DiskSpaceCompat {
  static const _channel =
      MethodChannel('dev.localvault.localvault/disk');

  static Future<int?> getTotalDiskSpace() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object>('getSpace');
      final total = map?['total'];
      if (total is int) return total;
      if (total is num) return total.toInt();
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<int?> getFreeDiskSpace() async {
    try {
      final map = await _channel.invokeMapMethod<String, Object>('getSpace');
      final free = map?['free'];
      if (free is int) return free;
      if (free is num) return free.toInt();
      return null;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
