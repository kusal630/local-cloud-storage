import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/utils/cipher.dart';
import '../database/vault_database.dart';
import '../models/shared_link.dart';

/// Public share links: unguessable tokens (only SHA-256 hashes stored),
/// optional expiry and password, download counting.
class ShareRepository {
  ShareRepository(this._db);

  final VaultDatabase _db;

  SharedLink _fromRow(Row row, {required String fileName}) => SharedLink(
        tokenPrefix: (row['token_prefix'] as String?) ?? '',
        fileId: row['file_id'] as String,
        fileName: fileName,
        hasPassword: (row['password_hash'] as String?) != null,
        expiresAt: row['expires_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['expires_at'] as int),
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
        downloadCount: (row['download_count'] as int?) ?? 0,
      );

  /// Creates a share and returns the plaintext token exactly once.
  Future<({String token, SharedLink link})> create({
    required String fileId,
    required String fileName,
    Duration? expiresIn,
    String? password,
  }) async {
    final token = Cipher.randomHex(32);
    final now = DateTime.now().millisecondsSinceEpoch;
    String? passwordHash;
    if (password != null && password.isNotEmpty) {
      passwordHash = await Cipher.hashPassword(password);
    }
    _db.raw.execute(
      '''
      INSERT INTO shares
        (token_hash, token_prefix, file_id, password_hash, expires_at,
         download_count, created_at)
      VALUES (?, ?, ?, ?, ?, 0, ?)
      ''',
      [
        Cipher.sha256String(token),
        token.substring(0, 12),
        fileId,
        passwordHash,
        expiresIn == null
            ? null
            : DateTime.now().add(expiresIn).millisecondsSinceEpoch,
        now,
      ],
    );
    return (
      token: token,
      link: SharedLink(
        tokenPrefix: token.substring(0, 12),
        fileId: fileId,
        fileName: fileName,
        hasPassword: passwordHash != null,
        expiresAt: expiresIn == null
            ? null
            : DateTime.now().add(expiresIn),
        createdAt: DateTime.fromMillisecondsSinceEpoch(now),
      ),
    );
  }

  Row _rowByTokenHash(String hash) {
    final rows = _db.raw.select(
      'SELECT * FROM shares WHERE token_hash = ?',
      [hash],
    );
    if (rows.isEmpty) throw const NotFoundException('Share not found.');
    return rows.first;
  }

  /// Validates a token; checks expiry. Does NOT check the password.
  Row resolve(String token) {
    final row = _rowByTokenHash(Cipher.sha256String(token));
    final expiresAt = row['expires_at'] as int?;
    if (expiresAt != null &&
        expiresAt < DateTime.now().millisecondsSinceEpoch) {
      throw const NotFoundException('Share expired.');
    }
    return row;
  }

  Future<bool> verifyPassword(Row row, String password) async {
    final hash = row['password_hash'] as String?;
    if (hash == null) return true;
    return Cipher.verifyPassword(password, hash);
  }

  void recordDownload(String tokenHash) {
    _db.raw.execute(
      'UPDATE shares SET download_count = download_count + 1 WHERE token_hash = ?',
      [tokenHash],
    );
  }

  List<SharedLink> listAll(Map<String, String> fileNames) {
    final rows = _db.raw.select(
      'SELECT * FROM shares ORDER BY created_at DESC',
    );
    return rows
        .map((r) => _fromRow(r,
            fileName: fileNames[r['file_id'] as String] ?? 'deleted file'))
        .toList();
  }

  void deleteByPrefix(String prefix) {
    _db.raw.execute(
      'DELETE FROM shares WHERE token_prefix = ?',
      [prefix],
    );
  }

  void deleteForFile(String fileId) {
    _db.raw.execute('DELETE FROM shares WHERE file_id = ?', [fileId]);
  }

  String newId() => const Uuid().v4();
}
