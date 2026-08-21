import 'package:sqlite3/sqlite3.dart';

import '../../core/errors/app_exceptions.dart';
import '../database/vault_database.dart';
import '../models/device.dart';

/// Stores only *hashes* of access and refresh tokens.
///
/// Access tokens expire after 15 minutes and are rotated through the refresh
/// endpoint. Refresh tokens last 30 days and are also rotated on use.
class DeviceRepository {
  DeviceRepository(this._db);

  final VaultDatabase _db;

  Device _fromRow(Row row) => Device(
        id: row['id'] as String,
        name: row['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        lastSeenAt: row['last_seen_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['last_seen_at'] as int),
        isCurrent: (row['is_current'] as int) == 1,
      );

  Device create({
    required String id,
    required String name,
    required String accessTokenHash,
    required int accessTokenExpiresAt,
    required String refreshTokenHash,
    required int refreshTokenExpiresAt,
    bool isCurrent = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _db.raw.execute(
      '''
      INSERT INTO devices
        (id, name, access_token_hash, access_token_expires_at,
         refresh_token_hash, refresh_token_expires_at,
         created_at, last_seen_at, revoked_at, is_current)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?)
      ''',
      [
        id,
        name,
        accessTokenHash,
        accessTokenExpiresAt,
        refreshTokenHash,
        refreshTokenExpiresAt,
        now,
        now,
        isCurrent ? 1 : 0,
      ],
    );
    return getById(id);
  }

  Device getById(String id) {
    final rows = _db.raw.select(
      'SELECT * FROM devices WHERE id = ? AND revoked_at IS NULL',
      [id],
    );
    if (rows.isEmpty) throw const NotFoundException('Device not found.');
    return _fromRow(rows.first);
  }

  /// Returns the first live (non-revoked) device with a matching name, if any.
  /// Used to keep device identity stable across reconnections.
  Device? findLiveByName(String name) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM devices
      WHERE name = ? AND revoked_at IS NULL
      ORDER BY created_at DESC LIMIT 1
      ''',
      [name],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Device? findByAccessTokenHash(String hash) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM devices
      WHERE access_token_hash = ?
        AND revoked_at IS NULL
        AND access_token_expires_at > ?
      ''',
      [hash, DateTime.now().millisecondsSinceEpoch],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  Device? findByRefreshTokenHash(String hash) {
    final rows = _db.raw.select(
      '''
      SELECT * FROM devices
      WHERE refresh_token_hash = ?
        AND revoked_at IS NULL
        AND refresh_token_expires_at > ?
      ''',
      [hash, DateTime.now().millisecondsSinceEpoch],
    );
    if (rows.isEmpty) return null;
    return _fromRow(rows.first);
  }

  List<Device> listAll() {
    final rows = _db.raw.select(
      'SELECT * FROM devices WHERE revoked_at IS NULL ORDER BY created_at ASC',
    );
    return rows.map(_fromRow).toList();
  }

  void updateLastSeen(String id, DateTime at) {
    _db.raw.execute(
      'UPDATE devices SET last_seen_at = ? WHERE id = ?',
      [at.millisecondsSinceEpoch, id],
    );
  }

  void rotateTokens({
    required String id,
    required String accessTokenHash,
    required int accessTokenExpiresAt,
    required String refreshTokenHash,
    required int refreshTokenExpiresAt,
  }) {
    _db.raw.execute(
      '''
      UPDATE devices SET
        access_token_hash = ?,
        access_token_expires_at = ?,
        refresh_token_hash = ?,
        refresh_token_expires_at = ?
      WHERE id = ?
      ''',
      [accessTokenHash, accessTokenExpiresAt, refreshTokenHash, refreshTokenExpiresAt, id],
    );
  }

  void clearTokens(String id) {
    _db.raw.execute(
      '''
      UPDATE devices SET
        access_token_hash = NULL,
        access_token_expires_at = NULL,
        refresh_token_hash = NULL,
        refresh_token_expires_at = NULL
      WHERE id = ?
      ''',
      [id],
    );
  }

  void revoke(String id) {
    final affected = _db.raw.select(
      'SELECT 1 FROM devices WHERE id = ? AND revoked_at IS NULL',
      [id],
    );
    if (affected.isEmpty) throw const NotFoundException('Device not found.');
    _db.raw.execute(
      'UPDATE devices SET revoked_at = ? WHERE id = ?',
      [DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void revokeAll() {
    _db.raw.execute(
      'UPDATE devices SET revoked_at = ? WHERE revoked_at IS NULL',
      [DateTime.now().millisecondsSinceEpoch],
    );
  }
}