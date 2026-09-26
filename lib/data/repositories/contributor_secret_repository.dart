import 'dart:typed_data';

import '../database/vault_database.dart';

/// Wrapped pairing secrets for pool contributors (RESEARCH/CONSULT.md §5).
///
/// Only AES-256-GCM ciphertext plus its fresh 12-byte nonce ever reach SQLite
/// — the master key lives in the platform keystore, never in the database.
class ContributorSecretRepository {
  ContributorSecretRepository(this._db);

  final VaultDatabase _db;

  /// Stores (or replaces) the wrapped pairing secret for [contributorId].
  void put(String contributorId, Uint8List wrapped, Uint8List wrapNonce) {
    _db.raw.execute(
      '''
      INSERT INTO contributor_secrets (contributor_id, wrapped, wrap_nonce)
      VALUES (?, ?, ?)
      ON CONFLICT(contributor_id) DO UPDATE SET
        wrapped = excluded.wrapped,
        wrap_nonce = excluded.wrap_nonce
      ''',
      [contributorId, wrapped, wrapNonce],
    );
  }

  /// Returns the wrapped secret as `(wrapped, wrapNonce)`, or null.
  ({Uint8List wrapped, Uint8List wrapNonce})? get(String contributorId) {
    final rows = _db.raw.select(
      'SELECT wrapped, wrap_nonce FROM contributor_secrets '
      'WHERE contributor_id = ?',
      [contributorId],
    );
    if (rows.isEmpty) return null;
    return (
      wrapped: rows.first['wrapped'] as Uint8List,
      wrapNonce: rows.first['wrap_nonce'] as Uint8List,
    );
  }

  /// Drops the stored secret (contributor fully removed).
  void delete(String contributorId) {
    _db.raw.execute(
      'DELETE FROM contributor_secrets WHERE contributor_id = ?',
      [contributorId],
    );
  }
}
