import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/utils/file_names.dart';
import '../database/vault_database.dart';
import '../models/vault_file.dart';
import 'blob_repository.dart';

/// Handles all file/folder metadata operations.
///
/// File bytes are never addressed by user-facing paths; operations work on
/// database rows only. Actual bytes live in the blob repository.
class FileRepository {
  FileRepository(this._db);

  final VaultDatabase _db;

  static const String typeFile = 'file';
  static const String typeFolder = 'folder';

  VaultFile _fromRow(Row row) => VaultFile(
        id: row['id'] as String,
        parentId: row['parent_id'] as String,
        name: row['name'] as String,
        type: row['type'] as String,
        mime: row['mime'] as String?,
        size: row['size'] as int,
        checksum: row['checksum'] as String?,
        blobId: row['blob_id'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        modifiedAt:
            DateTime.fromMillisecondsSinceEpoch(row['modified_at'] as int),
        deletedAt: row['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['deleted_at'] as int),
        hasThumb: (row['has_thumb'] as int?) == 1,
        isFavorite: (row['is_favorite'] as int?) == 1,
        lastOpenedAt: row['last_opened_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                row['last_opened_at'] as int),
        tags: parseTags(row['tags'] as String?),
      );

  /// Normalizes a tag list: lowercase, trimmed, deduped, bounded.
  static List<String> parseTags(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final out = <String>[];
    for (final part in raw.split(',')) {
      final tag = part.trim().toLowerCase();
      if (tag.isEmpty || out.contains(tag)) continue;
      if (!RegExp(r'^[a-z0-9][a-z0-9 _-]{0,30}[a-z0-9]?$').hasMatch(tag)) {
        continue;
      }      out.add(tag);
      if (out.length >= 10) break;
    }
    return out;
  }

  VaultFile setTags(String id, List<String> tags) {
    final entry = getById(id);
    if (entry.isTrashed) {
      throw const ValidationException('Trashed items cannot be tagged.');
    }
    _db.raw.execute(
      'UPDATE files SET tags = ?, modified_at = modified_at WHERE id = ?',
      [tags.join(','), id],
    );
    return getById(id);
  }

  List<({String tag, int count})> listTags() {
    final rows = _db.raw.select(
      '''
      SELECT tags FROM files
      WHERE deleted_at IS NULL AND tags != '' AND id != ?
      ''',
      [AppConstants.rootFolderId],
    );
    final counts = <String, int>{};
    for (final row in rows) {
      for (final tag in parseTags(row['tags'] as String?)) {
        counts[tag] = (counts[tag] ?? 0) + 1;
      }
    }
    final result = counts.entries
        .map((e) => (tag: e.key, count: e.value))
        .toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return result;
  }

  List<VaultFile> listByTag(String tag) {
    final clean = tag.trim().toLowerCase();
    final rows = _db.raw.select(
      r'''
      SELECT * FROM files
      WHERE deleted_at IS NULL AND id != ?
        AND (',' || tags || ',') LIKE ? ESCAPE '\'
      ORDER BY name COLLATE NOCASE ASC LIMIT 200
      ''',
      [AppConstants.rootFolderId, '%,${_escapeLike(clean)},%'],
    );
    return rows.map(_fromRow).toList();
  }

  /// Groups live files sharing a checksum (duplicate finder).
  List<({String checksum, int size, List<VaultFile> files})> duplicates(
      {int limit = 50}) {
    final groups = _db.raw.select(
      '''
      SELECT checksum, size, COUNT(*) AS n FROM files
      WHERE deleted_at IS NULL AND type = 'file'
        AND checksum IS NOT NULL AND id != ?
      GROUP BY checksum, size HAVING n > 1
      ORDER BY n DESC LIMIT ?
      ''',
      [AppConstants.rootFolderId, limit.clamp(1, 100)],
    );
    final out = <({String checksum, int size, List<VaultFile> files})>[];
    for (final g in groups) {
      final members = _db.raw.select(
        '''
        SELECT * FROM files
        WHERE deleted_at IS NULL AND checksum = ? AND size = ?
        ORDER BY modified_at ASC
        ''',
        [g['checksum'], g['size']],
      );
      out.add((
        checksum: g['checksum'] as String,
        size: (g['size'] as int?) ?? 0,
        files: members.map(_fromRow).toList(),
      ));
    }
    return out;
  }

  VaultFile setFavorite(String id, bool value) {
    final entry = getById(id);
    if (entry.isTrashed) {
      throw const ValidationException('Trashed items cannot be starred.');
    }
    _db.raw.execute(
      'UPDATE files SET is_favorite = ?, modified_at = modified_at WHERE id = ?',
      [value ? 1 : 0, id],
    );
    return getById(id);
  }

  List<VaultFile> listFavorites() {
    final rows = _db.raw.select(
      '''
      SELECT * FROM files
      WHERE deleted_at IS NULL AND is_favorite = 1 AND id != ?
      ORDER BY name COLLATE NOCASE ASC LIMIT 200
      ''',
      [AppConstants.rootFolderId],
    );
    return rows.map(_fromRow).toList();
  }

  void touchOpened(String id) {
    _db.raw.execute(
      'UPDATE files SET last_opened_at = ?, modified_at = modified_at WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  List<VaultFile> listRecent({int limit = 30}) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM files
      WHERE deleted_at IS NULL AND last_opened_at IS NOT NULL AND id != ?
      ORDER BY last_opened_at DESC LIMIT ?
      ''',
      [AppConstants.rootFolderId, limit.clamp(1, 100)],
    );
    return rows.map(_fromRow).toList();
  }

  VaultFile getById(String id) {
    final rows = _db.raw.select('SELECT * FROM files WHERE id = ?', [id]);
    if (rows.isEmpty) throw const NotFoundException('Item not found.');
    return _fromRow(rows.first);
  }

  void setHasThumb(String id, bool value) {
    _db.raw.execute(
      'UPDATE files SET has_thumb = ?, modified_at = modified_at WHERE id = ?',
      [value ? 1 : 0, id],
    );
  }

  /// Validates that [id] exists, is a live folder, and is not the root.
  void requireFolder(String id) {
    final folder = getById(id);
    if (folder.isTrashed) {
      throw const NotFoundException('Folder is in the trash.');
    }
    if (!folder.isFolder) {
      throw const ValidationException('Target is not a folder.');
    }
  }

  List<VaultFile> listChildren(
    String parentId, {
    bool includeTrashed = false,
  }) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM files
      WHERE parent_id = ?
        AND id != ?
        ${includeTrashed ? '' : 'AND deleted_at IS NULL'}
      ORDER BY
        CASE WHEN type = 'folder' THEN 0 ELSE 1 END,
        name COLLATE NOCASE ASC
      ''',
      [parentId, AppConstants.rootFolderId],
    );
    return rows.map(_fromRow).toList();
  }

  List<VaultFile> listTrash() {
    final rows = _db.raw.select(
      'SELECT * FROM files WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC',
    );
    return rows.map(_fromRow).toList();
  }

  List<VaultFile> search(String query) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM files
      WHERE deleted_at IS NULL
        AND id != ?
        AND name LIKE ? ESCAPE '\\'
      ORDER BY
        CASE WHEN type = 'folder' THEN 0 ELSE 1 END,
        name COLLATE NOCASE ASC
      LIMIT 200
      ''',
      [AppConstants.rootFolderId, '%${_escapeLike(query)}%'],
    );
    return rows.map(_fromRow).toList();
  }

  String _escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Computes the next available (non-conflicting) name for [parentId].
  String uniqueName(String parentId, String desired) {
    var candidate = desired;
    var attempt = 1;
    while (_nameExists(parentId, candidate)) {
      candidate = FileNames.numberedVariant(desired, attempt);
      attempt++;
      if (attempt > 1000) {
        throw const ConflictException('Too many conflicting names.');
      }
    }
    return candidate;
  }

  bool _nameExists(String parentId, String name) {
    final rows = _db.raw.select(
      '''
      SELECT 1 FROM files
      WHERE parent_id = ? AND name = ? AND deleted_at IS NULL
      LIMIT 1
      ''',
      [parentId, name],
    );
    return rows.isNotEmpty;
  }

  VaultFile createFolder(String parentId, String name) {
    requireFolder(parentId);
    final safeName = FileNames.sanitize(name);
    final finalName = uniqueName(parentId, safeName);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _newId();
    _db.raw.execute(
      '''
      INSERT INTO files (id, parent_id, name, type, size, created_at, modified_at)
      VALUES (?, ?, ?, ?, 0, ?, ?)
      ''',
      [id, parentId, finalName, typeFolder, now, now],
    );
    return getById(id);
  }

  VaultFile createFile({
    required String parentId,
    required String name,
    required int size,
    required String checksum,
    required String blobId,
    String? mime,
  }) {
    requireFolder(parentId);
    final safeName = FileNames.sanitize(name);
    final finalName = uniqueName(parentId, safeName);
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = _newId();
    _db.raw.execute(
      '''
      INSERT INTO files
        (id, parent_id, name, type, mime, size, blob_id, checksum,
         created_at, modified_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [id, parentId, finalName, typeFile, mime, size, blobId, checksum, now, now],
    );
    return getById(id);
  }

  VaultFile rename(String id, String newName) {
    final entry = getById(id);
    if (entry.id == AppConstants.rootFolderId) {
      throw const ValidationException('The root folder cannot be renamed.');
    }
    final safeName = FileNames.sanitize(newName);
    final finalName = uniqueName(entry.parentId, safeName);
    _db.raw.execute(
      '''
      UPDATE files SET name = ?, modified_at = ? WHERE id = ?
      ''',
      [finalName, DateTime.now().millisecondsSinceEpoch, id],
    );
    return getById(id);
  }

  /// Moves [id] into [newParentId]. Prevents circular moves and enforces name
  /// uniqueness in the target folder.
  VaultFile move(String id, String newParentId) {
    if (id == AppConstants.rootFolderId) {
      throw const ValidationException('The root folder cannot be moved.');
    }
    final entry = getById(id);
    if (entry.isTrashed) {
      throw const ValidationException('Trashed items cannot be moved.');
    }
    requireFolder(newParentId);
    if (newParentId == entry.parentId) {
      return entry;
    }
    if (entry.isFolder) {
      final ancestorIds = _ancestorIds(newParentId);
      if (ancestorIds.contains(id)) {
        throw const ValidationException(
            'Cannot move a folder into itself or one of its sub-folders.');
      }
    }
    final finalName = uniqueName(newParentId, entry.name);
    _db.raw.execute(
      '''
      UPDATE files SET parent_id = ?, name = ?, modified_at = ? WHERE id = ?
      ''',
      [newParentId, finalName, DateTime.now().millisecondsSinceEpoch, id],
    );
    return getById(id);
  }

  /// Returns the list of parent ids from [id] up to (and including) root.
  List<String> _ancestorIds(String id) {
    final result = <String>[];
    var current = id;
    var guard = 0;
    while (current != AppConstants.rootFolderId && guard < 10000) {
      final rows = _db.raw.select(
        'SELECT parent_id FROM files WHERE id = ?',
        [current],
      );
      if (rows.isEmpty) return result;
      current = rows.first['parent_id'] as String;
      result.add(current);
      guard++;
    }
    return result;
  }

  /// Soft-deletes [id] and everything below it recursively.
  void softDelete(String id) {
    if (id == AppConstants.rootFolderId) {
      throw const ValidationException('The root folder cannot be deleted.');
    }
    final entry = getById(id);
    if (entry.isTrashed) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT id FROM files WHERE id = ?
        UNION ALL
        SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
      )
      UPDATE files SET deleted_at = ? WHERE id IN (SELECT id FROM subtree)
      ''',
      [id, now],
    );
  }

  /// Restores [id] and all its descendants.
  ///
  /// If the restored name collides with a live entry, the restored item is
  /// auto-renamed (e.g. `folder (1)`).
  VaultFile restore(String id) {
    final entry = getById(id);
    if (!entry.isTrashed) return entry;

    return _db.withTransaction(() {
      final finalName = _nameExists(entry.parentId, entry.name)
          ? uniqueName(entry.parentId, entry.name)
          : entry.name;
      _db.raw.execute(
        'UPDATE files SET deleted_at = NULL, name = ?, modified_at = ? WHERE id = ?',
        [finalName, DateTime.now().millisecondsSinceEpoch, id],
      );
      _db.raw.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT id FROM files WHERE parent_id = ?
          UNION ALL
          SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
        )
        UPDATE files SET deleted_at = NULL, modified_at = ?
        WHERE id IN (SELECT id FROM subtree)
        ''',
        [id, DateTime.now().millisecondsSinceEpoch],
      );
      return getById(id);
    });
  }

  /// Permanently deletes [id] (recursively) and returns blob records whose
  /// backing files are no longer referenced anywhere.
  ///
  /// Blob disk files must be removed by the caller using [BlobRecord.relPath].
  List<BlobRecord> permanentDelete(String id, BlobRepository blobs) {
    return _db.withTransaction(() {
      final orphaned = <BlobRecord>[];
      final blobIds = _descendantBlobIds(id);
      _db.raw.execute('DELETE FROM files WHERE id = ? OR parent_id = ?', [id, id]);
      _db.raw.execute(
        '''
        WITH RECURSIVE subtree(id) AS (
          SELECT id FROM files WHERE parent_id = ?
          UNION ALL
          SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
        )
        DELETE FROM files WHERE id IN (SELECT id FROM subtree)
        ''',
        [id],
      );
      for (final blobId in blobIds) {
        if (blobs.deleteIfUnused(blobId)) {
          orphaned.add(blobs.getById(blobId));
        }
      }
      _db.raw.execute(
        'DELETE FROM file_versions WHERE file_id NOT IN (SELECT id FROM files)',
      );
      _pruneDanglingMeta();
      return orphaned;
    });
  }

  /// Permanently deletes everything in the trash.
  List<BlobRecord> emptyTrash(BlobRepository blobs) {
    return _db.withTransaction(() {
      final orphaned = <BlobRecord>[];
      final rows = _db.raw.select(
        'SELECT id FROM files WHERE deleted_at IS NOT NULL',
      );
      final blobIds = <String>{};
      for (final row in rows) {
        blobIds.addAll(_descendantBlobIds(row['id'] as String));
      }
      _db.raw.execute('DELETE FROM files WHERE deleted_at IS NOT NULL');
      _db.raw.execute(
        'DELETE FROM file_versions WHERE file_id NOT IN (SELECT id FROM files)',
      );
      _pruneDanglingMeta();
      for (final blobId in blobIds) {
        if (blobs.deleteIfUnused(blobId)) {
          orphaned.add(blobs.getById(blobId));
        }
      }
      return orphaned;
    });
  }

  /// Drops comments/shares/versions whose file rows are gone.
  void _pruneDanglingMeta() {
    _db.raw.execute(
      'DELETE FROM file_versions WHERE file_id NOT IN (SELECT id FROM files)',
    );
    _db.raw.execute(
      'DELETE FROM comments WHERE file_id NOT IN (SELECT id FROM files)',
    );
    _db.raw.execute(
      'DELETE FROM shares WHERE file_id NOT IN (SELECT id FROM files) AND file_id != \'\'',
    );
  }

  List<String> _descendantBlobIds(String id) {    final rows = _db.raw.select(
      '''
      WITH RECURSIVE subtree(id) AS (
        SELECT id FROM files WHERE id = ?
        UNION ALL
        SELECT f.id FROM files f JOIN subtree s ON f.parent_id = s.id
      )
      SELECT blob_id FROM files WHERE id IN (SELECT id FROM subtree) AND blob_id IS NOT NULL
      ''',
      [id],
    );
    return rows.map((r) => r['blob_id'] as String).toList();
  }

  /// Usage in bytes of live and trashed files.
  ({int vaultBytes, int trashBytes}) usage() {    final row = _db.raw.select(
      '''
      SELECT
        SUM(CASE WHEN deleted_at IS NULL THEN size ELSE 0 END) AS vault_bytes,
        SUM(CASE WHEN deleted_at IS NOT NULL THEN size ELSE 0 END) AS trash_bytes
      FROM files
      ''',
    ).first;
    return (
      vaultBytes: (row['vault_bytes'] as int?) ?? 0,
      trashBytes: (row['trash_bytes'] as int?) ?? 0,
    );
  }

  /// Bytes per file category across live files (for the breakdown chart).
  Map<String, int> breakdown() {
    final rows = _db.raw.select(
      '''
      SELECT name, mime, size FROM files
      WHERE deleted_at IS NULL AND type = ? AND id != ?
      ''',
      [typeFile, AppConstants.rootFolderId],
    );
    final result = <String, int>{
      'images': 0,
      'video': 0,
      'audio': 0,
      'docs': 0,
      'archives': 0,
      'other': 0,
    };
    for (final row in rows) {
      final cat = _categoryOf(
        row['name'] as String,
        row['mime'] as String?,
      );
      result[cat] = (result[cat] ?? 0) + ((row['size'] as int?) ?? 0);
    }
    return result;
  }

  String _categoryOf(String name, String? mime) {
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/')) return 'images';
    if (m.startsWith('video/')) return 'video';
    if (m.startsWith('audio/')) return 'audio';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'svg'}
        .contains(ext)) {
      return 'images';
    }
    if (const {'mp4', 'mkv', 'mov', 'avi', 'webm'}.contains(ext)) {
      return 'video';
    }
    if (const {'mp3', 'wav', 'flac', 'ogg', 'm4a'}.contains(ext)) {
      return 'audio';
    }
    if (const {
      'pdf',
      'doc',
      'docx',
      'txt',
      'md',
      'rtf',
      'xls',
      'xlsx',
      'csv',
      'ppt',
      'pptx'
    }.contains(ext)) {
      return 'docs';
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return 'archives';
    }
    return 'other';
  }

  /// Permanently deletes trashed items older than [cutoff] and returns blob
  /// records that lost their last reference.
  List<BlobRecord> purgeTrashOlderThan(
      DateTime cutoff, BlobRepository blobs) {
    return _db.withTransaction(() {
      final orphaned = <BlobRecord>[];
      final rows = _db.raw.select(
        'SELECT id FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?',
        [cutoff.millisecondsSinceEpoch],
      );
      final blobIds = <String>{};
      for (final row in rows) {
        blobIds.addAll(_descendantBlobIds(row['id'] as String));
      }
      _db.raw.execute(
        'DELETE FROM files WHERE deleted_at IS NOT NULL AND deleted_at < ?',
        [cutoff.millisecondsSinceEpoch],
      );
      // Detach versions/meta of files that no longer exist.
      _pruneDanglingMeta();
      for (final blobId in blobIds) {
        if (blobs.deleteIfUnused(blobId)) {
          orphaned.add(blobs.getById(blobId));
        }
      }
      return orphaned;
    });
  }

  /// Points [id] at a new blob (used by replace-upload after snapshotting).
  VaultFile replaceContent({
    required String id,
    required String blobId,
    required int size,
    required String checksum,
    String? mime,
  }) {
    final entry = getById(id);
    if (entry.isTrashed || entry.isFolder) {
      throw const ValidationException('Only live files can be replaced.');
    }
    _db.raw.execute(
      '''
      UPDATE files
      SET blob_id = ?, size = ?, checksum = ?, mime = ?, has_thumb = 0,
          modified_at = ?
      WHERE id = ?
      ''',
      [
        blobId,
        size,
        checksum,
        mime,
        DateTime.now().millisecondsSinceEpoch,
        id
      ],
    );
    return getById(id);
  }

  /// Deep-copies [id] (files share blobs; folders recurse) into
  /// [targetParentId]. Names auto-resolve conflicts.
  VaultFile copyItem(String id, String targetParentId) {
    final entry = getById(id);
    if (entry.id == AppConstants.rootFolderId) {
      throw const ValidationException('The root folder cannot be copied.');
    }
    if (entry.isTrashed) {
      throw const ValidationException('Trashed items cannot be copied.');
    }
    requireFolder(targetParentId);
    if (entry.isFolder) {
      if (targetParentId == id ||
          _ancestorIds(targetParentId).contains(id)) {
        throw const ValidationException(
            'Cannot copy a folder into itself or its sub-folders.');
      }
    }
    return _db.withTransaction(() => _copyInto(entry, targetParentId));
  }

  VaultFile _copyInto(VaultFile entry, String parentId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final newId = _newId();
    if (!entry.isFolder) {
      _db.raw.execute(
        '''
        INSERT INTO files
          (id, parent_id, name, type, mime, size, blob_id, checksum,
           has_thumb, is_favorite, tags, created_at, modified_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)
        ''',
        [
          newId,
          parentId,
          uniqueName(parentId, entry.name),
          typeFile,
          entry.mime,
          entry.size,
          entry.blobId,
          entry.checksum,
          entry.tags.join(','),
          now,
          now,
        ],
      );
      return getById(newId);
    }
    _db.raw.execute(
      '''
      INSERT INTO files (id, parent_id, name, type, size, tags, created_at, modified_at)
      VALUES (?, ?, ?, ?, 0, ?, ?, ?)
      ''',
      [
        newId,
        parentId,
        uniqueName(parentId, entry.name),
        typeFolder,
        entry.tags.join(','),
        now,
        now,
      ],
    );
    for (final child in listChildren(entry.id, includeTrashed: false)) {
      _copyInto(child, newId);
    }
    return getById(newId);
  }

  String _newId() {
    var id = '';
    var guard = 0;
    do {
      id = const Uuid().v4();
      final existing = _db.raw.select('SELECT 1 FROM files WHERE id = ?', [id]);
      if (existing.isEmpty) return id;
      guard++;
    } while (guard < 100);
    throw const DatabaseException('Could not allocate a unique file id.');
  }
}