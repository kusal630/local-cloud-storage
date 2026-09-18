import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import '../database/vault_database.dart';
import '../models/audit_entry.dart';

/// Append-only host-side activity log (uploads, renames, deletes, …).
class AuditRepository {
  AuditRepository(this._db);

  final VaultDatabase _db;

  AuditEntry _fromRow(Row row) => AuditEntry(
        id: row['id'] as String,
        deviceId: row['device_id'] as String?,
        action: row['action'] as String,
        targetId: row['target_id'] as String?,
        targetName: row['target_name'] as String?,
        detail: row['detail'] as String?,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );

  void record({
    String? deviceId,
    required String action,
    String? targetId,
    String? targetName,
    String? detail,
  }) {
    try {
      _db.raw.execute(
        '''
        INSERT INTO audit_log
          (id, device_id, action, target_id, target_name, detail, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          const Uuid().v4(),
          deviceId,
          action,
          targetId,
          targetName,
          detail,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
      // Bound the log: keep newest 500 rows.
      _db.raw.execute(
        '''
        DELETE FROM audit_log WHERE id NOT IN (
          SELECT id FROM audit_log ORDER BY created_at DESC LIMIT 500
        )
        ''',
      );
    } catch (_) {
      // Audit must never break the primary operation.
    }
  }

  List<AuditEntry> recent({int limit = 50}) {
    final rows = _db.raw.select(
      'SELECT * FROM audit_log ORDER BY created_at DESC LIMIT ?',
      [limit.clamp(1, 200)],
    );
    return rows.map(_fromRow).toList();
  }
}
