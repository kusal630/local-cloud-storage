import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/models/vault_file.dart';
import 'file_service.dart';

/// Pinned files available without the host (offline copies in app storage).
class OfflineService extends ChangeNotifier {
  OfflineService(this._files);

  final FileService _files;

  static const _key = 'offline_entries_v1';

  final Map<String, OfflineEntry> _entries = {};

  List<OfflineEntry> get entries => _entries.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  bool isPinned(String id) => _entries.containsKey(id);

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'offline'));
    await dir.create(recursive: true);
    return dir;
  }

  String _fileName(String id, String name) {
    final safe = name.replaceAll(RegExp(r'[^\w.\- ]'), '_');
    return '${id}_$safe';
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      for (final m in list) {
        final e = OfflineEntry.fromJson(m);
        final dir = await _dir();
        if (await File(p.join(dir.path, e.fileName)).exists()) {
          _entries[e.id] = e;
        }
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key,
          jsonEncode(_entries.values.map((e) => e.toJson()).toList()));
    } catch (_) {}
  }

  /// Downloads and pins [file] for offline use.
  Future<void> pin(VaultFile file) async {
    final dir = await _dir();
    final fileName = _fileName(file.id, file.name);
    final bytes = await _files.downloadBytes(file.id);
    await File(p.join(dir.path, fileName)).writeAsBytes(bytes);
    _entries[file.id] = OfflineEntry(
      id: file.id,
      name: file.name,
      size: file.size,
      checksum: file.checksum ?? '',
      modifiedAt: file.modifiedAt.toIso8601String(),
      fileName: fileName,
    );
    await _save();
    notifyListeners();
  }

  Future<void> unpin(String id) async {
    final entry = _entries.remove(id);
    if (entry != null) {
      try {
        final dir = await _dir();
        final f = File(p.join(dir.path, entry.fileName));
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }

  Future<String?> localPath(String id) async {
    final entry = _entries[id];
    if (entry == null) return null;
    final dir = await _dir();
    final path = p.join(dir.path, entry.fileName);
    return await File(path).exists() ? path : null;
  }

  /// Synthetic rows so the files UI can render offline entries.
  List<VaultFile> asVaultFiles() => [
        for (final e in entries)
          VaultFile(
            id: e.id,
            parentId: '',
            name: e.name,
            type: 'file',
            size: e.size,
            checksum: e.checksum.isEmpty ? null : e.checksum,
            createdAt:
                DateTime.tryParse(e.modifiedAt) ?? DateTime.now(),
            modifiedAt:
                DateTime.tryParse(e.modifiedAt) ?? DateTime.now(),
          ),
      ];
}

class OfflineEntry {
  OfflineEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.checksum,
    required this.modifiedAt,
    required this.fileName,
  });

  final String id;
  final String name;
  final int size;
  final String checksum;
  final String modifiedAt;
  final String fileName;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'size': size,
        'checksum': checksum,
        'modifiedAt': modifiedAt,
        'fileName': fileName,
      };

  static OfflineEntry fromJson(Map<String, dynamic> m) => OfflineEntry(
        id: m['id'] as String,
        name: m['name'] as String,
        size: (m['size'] as num).toInt(),
        checksum: m['checksum'] as String? ?? '',
        modifiedAt: m['modifiedAt'] as String? ?? '',
        fileName: m['fileName'] as String? ?? '',
      );
}
