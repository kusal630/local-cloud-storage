import 'dart:io';

import 'package:flutter/services.dart';

/// Disk-space queries across platforms.
///
/// Android is served from MainActivity (StatFs). Desktop falls back to OS
/// tools (`df` on Linux/macOS, PowerShell on Windows). Returns null when
/// unavailable — callers must treat null as "unknown", never as zero.
abstract class DiskSpaceCompat {
  static const _channel =
      MethodChannel('dev.localvault.localvault/disk');

  static Future<({int total, int free})?> getSpace(String path) async {
    // 1. Native channel (Android).
    try {
      final map = await _channel.invokeMapMethod<String, Object>('getSpace');
      if (map != null) {
        final total = _asInt(map['total']);
        final free = _asInt(map['free']);
        if (total != null && free != null && total > 0) {
          return (total: total, free: free);
        }
      }
    } on MissingPluginException {
      // Not Android — fall through to OS tools.
    } on PlatformException {
      // Fall through.
    } catch (_) {}
    // 2. Desktop OS tools.
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        return await _df(path);
      }
      if (Platform.isWindows) {
        return await _windows(path);
      }
    } catch (_) {}
    return null;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return null;
  }

  /// Parses `df -k <path>`: second line is `<fs> <1K-blocks> <used> <avail>`.
  static Future<({int total, int free})?> _df(String path) async {
    final result = await Process.run('df', ['-k', path.isEmpty ? '/' : path]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String).trim().split('\n');
    if (lines.length < 2) return null;
    final cols = lines[1].trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final total = int.tryParse(cols[1]);
    final free = int.tryParse(cols[3]);
    if (total == null || free == null || total <= 0) return null;
    return (total: total * 1024, free: free * 1024);
  }

  /// PowerShell drive query for the drive holding [path].
  static Future<({int total, int free})?> _windows(String path) async {
    var drive = 'C';
    final match = RegExp(r'^([A-Za-z]):').firstMatch(path);
    if (match != null) drive = match.group(1)!.toUpperCase();
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-PSDrive $drive).Used + 0; (Get-PSDrive $drive).Free + 0',
    ]);
    if (result.exitCode != 0) return null;
    final lines = (result.stdout as String)
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.length < 2) return null;
    final used = int.tryParse(lines[0]);
    final free = int.tryParse(lines[1]);
    if (used == null || free == null || used + free <= 0) return null;
    return (total: used + free, free: free);
  }
}
