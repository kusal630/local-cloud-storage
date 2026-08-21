import '../database/vault_database.dart';

/// Key/value host settings stored in the vault SQLite database.
class SettingsRepository {
  SettingsRepository(this._db);

  final VaultDatabase _db;

  static const String passwordHashKey = 'password_hash';
  static const String setupCompleteKey = 'setup_complete';
  static const String storageRootKey = 'storage_root';
  static const String serverPortKey = 'server_port';
  static const String hostDeviceNameKey = 'host_device_name';

  String? get(String key) {
    final rows = _db.raw.select(
      'SELECT value FROM settings WHERE key = ?',
      [key],
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  void set(String key, String value) {
    _db.raw.execute(
      '''
      INSERT INTO settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      ''',
      [key, value],
    );
  }

  String? get passwordHash => get(passwordHashKey);

  set passwordHash(String? value) => _setOrDelete(passwordHashKey, value);

  bool get setupComplete => get(setupCompleteKey) == '1';

  set setupComplete(bool value) => set(setupCompleteKey, value ? '1' : '0');

  String? get storageRoot => get(storageRootKey);

  set storageRoot(String? value) => _setOrDelete(storageRootKey, value);

  int get serverPort {
    final raw = get(serverPortKey);
    if (raw == null) return 8484;
    return int.tryParse(raw) ?? 8484;
  }

  set serverPort(int value) => set(serverPortKey, '$value');

  String get hostDeviceName =>
      get(hostDeviceNameKey) ?? 'My LocalVault';

  set hostDeviceName(String value) => set(hostDeviceNameKey, value);

  void _setOrDelete(String key, String? value) {
    if (value == null) {
      _db.raw.execute('DELETE FROM settings WHERE key = ?', [key]);
    } else {
      set(key, value);
    }
  }
}