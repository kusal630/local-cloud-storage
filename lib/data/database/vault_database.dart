import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';

/// Opens and migrates the vault SQLite database located at
/// `<vaultDir>/db.sqlite`.
class VaultDatabase {
  VaultDatabase._(this._db);

  final Database _db;

  /// Opens (creating if necessary) the database inside [vaultDir].
  static VaultDatabase open(Directory vaultDir) {
    final dbFile = File('${vaultDir.path}${Platform.pathSeparator}${AppConstants.dbFileName}');
    try {
      final db = sqlite3.open(dbFile.path);
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('PRAGMA busy_timeout = 5000;');
      final manager = VaultDatabase._(db);
      manager._migrate();
      return manager;
    } catch (e, st) {
      logError('Failed to open vault database', e, st);
      throw DatabaseException('Could not open vault database: $e', cause: e);
    }
  }

  Database get raw => _db;

  void _migrate() {
    _db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      ) STRICT;
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id                       TEXT PRIMARY KEY,
        name                     TEXT NOT NULL,
        access_token_hash        TEXT,
        access_token_expires_at  INTEGER,
        refresh_token_hash       TEXT,
        refresh_token_expires_at INTEGER,
        created_at               INTEGER NOT NULL,
        last_seen_at             INTEGER,
        revoked_at               INTEGER,
        is_current               INTEGER NOT NULL DEFAULT 0
      ) STRICT;
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS blobs (
        id         TEXT PRIMARY KEY,
        size       INTEGER NOT NULL,
        checksum   TEXT NOT NULL,
        mime       TEXT,
        rel_path   TEXT NOT NULL,
        created_at INTEGER NOT NULL
      ) STRICT;
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS files (
        id          TEXT PRIMARY KEY,
        parent_id   TEXT NOT NULL,
        name        TEXT NOT NULL,
        type        TEXT NOT NULL,
        mime        TEXT,
        size        INTEGER NOT NULL DEFAULT 0,
        blob_id     TEXT,
        checksum    TEXT,
        has_thumb   INTEGER NOT NULL DEFAULT 0,
        created_at  INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        deleted_at  INTEGER,
        FOREIGN KEY (parent_id) REFERENCES files(id) ON DELETE CASCADE,
        FOREIGN KEY (blob_id)   REFERENCES blobs(id) ON DELETE SET NULL
      ) STRICT;
    ''');
    // Unique name for live (non-deleted) entries within the same parent.
    _db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_files_live_name
        ON files(parent_id, name) WHERE deleted_at IS NULL;
    ''');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS upload_sessions (
        id               TEXT PRIMARY KEY,
        parent_id        TEXT NOT NULL,
        name             TEXT NOT NULL,
        size             INTEGER NOT NULL,
        expected_checksum TEXT NOT NULL,
        tmp_path         TEXT NOT NULL,
        received         INTEGER NOT NULL DEFAULT 0,
        chunk_count      INTEGER NOT NULL DEFAULT 0,
        mime             TEXT,
        device_id        TEXT,
        status           TEXT NOT NULL DEFAULT 'active',
        created_at       INTEGER NOT NULL,
        updated_at       INTEGER NOT NULL
      ) STRICT;
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_files_parent ON files(parent_id);
    ''');
    _db.execute('''
      CREATE INDEX IF NOT EXISTS idx_files_deleted ON files(deleted_at);
    ''');

    // Seed the virtual root folder.
    final roots = _db.select(
      "SELECT id FROM files WHERE id = ?",
      [AppConstants.rootFolderId],
    );
    if (roots.isEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _db.execute(
        '''
        INSERT INTO files (id, parent_id, name, type, size, created_at, modified_at)
        VALUES (?, ?, ?, ?, 0, ?, ?)
        ''',
        [AppConstants.rootFolderId, AppConstants.rootFolderId, 'root', 'folder', now, now],
      );
    }
  }

  /// Runs [action] inside a transaction, rolling back on error.
  T withTransaction<T>(T Function() action) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _db.execute('COMMIT');
      return result;
    } catch (e) {
      try {
        _db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  void close() {
    _db.close();
  }
}