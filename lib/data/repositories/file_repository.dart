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
      );

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
      for (final blobId in blobIds) {
        if (blobs.deleteIfUnused(blobId)) {
          orphaned.add(blobs.getById(blobId));
        }
      }
      return orphaned;
    });
  }

  List<String> _descendantBlobIds(String id) {
    final rows = _db.raw.select(
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
  ({int vaultBytes, int trashBytes}) usage() {
    final row = _db.raw.select(
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