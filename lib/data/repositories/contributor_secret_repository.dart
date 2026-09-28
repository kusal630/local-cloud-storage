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

  // --- Node capability tokens (CONSULT §1) -------------------------------
  //
  // The coordinator must be able to *call* a contributor's storage node, so
  // it keeps the token it issued — but only as master-KEK-wrapped ciphertext
  // with AAD `node-token:<id>`, which is why this lives in its own table and
  // can never be confused with a wrapped pairing secret (§5 domain
  // separation). The SHA-256 of the same token is what `contributors.
  // token_hash` checks when the contributor calls *us*.

  /// Stores (or replaces) the wrapped node token for [contributorId].
  void putNodeToken(String contributorId, Uint8List wrapped) {
    _db.raw.execute(
      '''
      INSERT INTO contributor_node_tokens (contributor_id, wrapped)
      VALUES (?, ?)
      ON CONFLICT(contributor_id) DO UPDATE SET
        wrapped = excluded.wrapped
      ''',
      [contributorId, wrapped],
    );
  }

  /// Returns the wrapped node token, or null when never issued.
  Uint8List? getNodeToken(String contributorId) {
    final rows = _db.raw.select(
      'SELECT wrapped FROM contributor_node_tokens WHERE contributor_id = ?',
      [contributorId],
    );
    if (rows.isEmpty) return null;
    return rows.first['wrapped'] as Uint8List;
  }

  /// Drops the wrapped node token (revoke / leave).
  void deleteNodeToken(String contributorId) {
    _db.raw.execute(
      'DELETE FROM contributor_node_tokens WHERE contributor_id = ?',
      [contributorId],
    );
  }
}
