import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'backup_worker.dart';
import 'file_service.dart';
import 'transfer_manager.dart';

String _shaFile(String path) {
  final bytes = File(path).readAsBytesSync();
  return sha256.convert(bytes).toString();
}

/// Phone-style auto backup: watches user-chosen folders and uploads new
/// files to `Auto Backup` on the cloud, skipping already-uploaded content by
/// checksum. Runs in-app (foreground); enable + "Backup now" in Settings.
class BackupService extends ChangeNotifier {
  BackupService(this._files, this._transfers);

  final FileService _files;
  final TransferManager _transfers;

  static const _enabledKey = 'backup_enabled';
  static const _sourcesKey = 'backup_sources';
  static const _knownKey = 'backup_known_checksums';
  static const _lastRunKey = 'backup_last_run';
  static const _lastAddedKey = 'backup_last_added';
  static const _lastScannedKey = 'backup_last_scanned';
  static const _ignoresKey = 'backup_ignore_patterns';
  static const _organizeKey = 'backup_organize_month';
  static const _bgKey = 'backup_bg_enabled';
  static const bgTaskName = 'localvault-backup';
  static const bgUniqueName = 'localvault-backup-periodic';

  /// Files larger than this are skipped (500 MB).
  static const int maxFileBytes = 500 * 1024 * 1024;
  static const int knownCap = 2000;

  bool enabled = false;
  List<String> sources = [];
  bool running = false;
  String? error;
  DateTime? lastRun;
  int lastAdded = 0;
  int lastScanned = 0;
  bool backgroundEnabled = false;
  /// Syncthing-style ignore substrings (`*` wildcard), comma-separated in UI.
  List<String> ignorePatterns = [];
  /// When true, uploads land in `Auto Backup/<device>/2026-09` by file date.
  bool organizeByMonth = true;

  /// Pure helper (unit-tested): true when [path] matches any ignore pattern.
  /// `*` acts as a wildcard; plain text matches as a substring.
  /// Matching runs against the full path and the bare file name.
  static bool matchesIgnore(String path, List<String> patterns) {
    final targets = [path.toLowerCase(), p.basename(path).toLowerCase()];
    for (final raw in patterns) {
      final pattern = raw.trim().toLowerCase();
      if (pattern.isEmpty) continue;
      for (final target in targets) {
        if (pattern.contains('*')) {
          final regex = RegExp(
            '^${RegExp.escape(pattern).replaceAll('\\*', '.*')}\$',
          );
          if (regex.hasMatch(target)) return true;
        } else if (target.contains(pattern)) {
          return true;
        }
      }
    }
    return false;
  }

  /// Pure helper (unit-tested): true when [name]/[size] should be skipped.
  static bool shouldSkip(String name, int size) {
    if (size <= 0 || size > maxFileBytes) return true;
    final base = p.basename(name);
    if (base.startsWith('.')) return true;
    const ignored = {'tmp', 'temp', 'log', 'cache', 'thumb', 'db-journal'};
    final ext = base.contains('.') ? base.split('.').last.toLowerCase() : '';
    if (ignored.contains(ext)) return true;
    return false;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_enabledKey) ?? false;
      sources = prefs.getStringList(_sourcesKey) ?? [];
      ignorePatterns = (prefs.getString(_ignoresKey) ?? '')
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      organizeByMonth = prefs.getBool(_organizeKey) ?? true;
      backgroundEnabled = prefs.getBool(_bgKey) ?? false;
      final last = prefs.getString(_lastRunKey);
      lastRun = last == null ? null : DateTime.tryParse(last);
      lastAdded = prefs.getInt(_lastAddedKey) ?? 0;
      lastScanned = prefs.getInt(_lastScannedKey) ?? 0;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {}
  }

  Future<void> addSource(String path) async {
    if (sources.contains(path)) return;
    sources = [...sources, path];
    notifyListeners();
    await _saveSources();
  }

  Future<void> removeSource(String path) async {
    sources = sources.where((s) => s != path).toList();
    notifyListeners();
    await _saveSources();
  }

  Future<void> setIgnorePatterns(String commaSeparated) async {
    ignorePatterns = commaSeparated
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ignoresKey, commaSeparated);
    } catch (_) {}
  }

  Future<void> setOrganizeByMonth(bool value) async {
    organizeByMonth = value;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_organizeKey, value);
    } catch (_) {}
  }

  static bool get supportsBackground =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Enables periodic background backup (Android WorkManager / iOS refresh).
  /// Runs roughly every 6 hours while the OS allows it.
  Future<void> setBackgroundEnabled(bool value) async {
    if (value && !supportsBackground) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_bgKey, value);
      if (value) {
        await Workmanager().initialize(backupCallbackDispatcher);
        await Workmanager().registerPeriodicTask(
          bgUniqueName,
          bgTaskName,
          frequency: const Duration(hours: 6),
          constraints: Constraints(networkType: NetworkType.connected),
        );
      } else {
        try {
          await Workmanager().cancelByUniqueName(bgUniqueName);
        } catch (_) {}
      }
      backgroundEnabled = value;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _saveSources() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_sourcesKey, sources);
    } catch (_) {}
  }

  /// Scans sources and queues uploads for new files.
  Future<void> runBackup({required String deviceName}) async {
    if (running) return;
    running = true;
    error = null;
    lastAdded = 0;
    lastScanned = 0;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final known = (prefs.getStringList(_knownKey) ?? []).toSet();

      final targetId = await _ensureBackupFolder(deviceName);
      for (final src in sources) {
        final dir = Directory(src);
        if (!await dir.exists()) continue;
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          int size;
          DateTime modified;
          try {
            final stat = await entity.stat();
            size = stat.size;
            modified = stat.modified;
          } catch (_) {
            continue;
          }
          lastScanned++;
          if (shouldSkip(entity.path, size)) continue;
          if (matchesIgnore(entity.path, ignorePatterns)) continue;
          String checksum;
          try {
            checksum = await compute(_shaFile, entity.path);
          } catch (_) {
            continue;
          }
          if (known.contains(checksum)) continue;
          known.add(checksum);
          if (known.length > knownCap) {
            known.remove(known.first);
          }
          var parentId = targetId;
          if (organizeByMonth) {
            final bucket =
                '${modified.year}-${modified.month.toString().padLeft(2, '0')}';
            parentId = await _ensureFolder(targetId, bucket);
          }
          _transfers.enqueueUpload(
            sourcePath: entity.path,
            parentId: parentId,
            name: p.basename(entity.path),
          );
          lastAdded++;
        }
      }
      lastRun = DateTime.now();
      await prefs.setStringList(_knownKey, known.toList());
      await prefs.setString(_lastRunKey, lastRun!.toIso8601String());
      await prefs.setInt(_lastAddedKey, lastAdded);
      await prefs.setInt(_lastScannedKey, lastScanned);
    } catch (e) {
      error = e.toString();
    } finally {
      running = false;
      notifyListeners();
    }
  }

  /// Finds or creates `Auto Backup/<deviceName>` and returns its id.
  Future<String> _ensureBackupFolder(String deviceName) async {
    final rootItems = await _files.listFiles('root');
    var backup = rootItems.where((f) => f.isFolder && f.name == 'Auto Backup');
    final backupId = backup.isEmpty
        ? (await _files.createFolder('root', 'Auto Backup')).id
        : backup.first.id;
    final safeDevice =
        deviceName.trim().isEmpty ? 'device' : deviceName.trim();
    return _ensureFolder(backupId, safeDevice);
  }

  Future<String> _ensureFolder(String parentId, String name) async {
    final children = await _files.listFiles(parentId);
    final match = children.where(
        (f) => f.isFolder && f.name.toLowerCase() == name.toLowerCase());
    if (match.isNotEmpty) return match.first.id;
    return (await _files.createFolder(parentId, name)).id;
  }
}
