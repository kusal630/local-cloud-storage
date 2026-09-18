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
  static const String ownerUsernameKey = 'owner_username';
  static const String trashRetentionDaysKey = 'trash_retention_days';
  static const String deviceQuotaBytesKey = 'device_quota_bytes';
  static const String tlsCertPathKey = 'tls_cert_path';
  static const String tlsKeyPathKey = 'tls_key_path';
  static const String dataVersionKey = 'data_version';

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

  /// Owner login name for password access. Defaults to 'owner'.
  String get ownerUsername =>
      (get(ownerUsernameKey) ?? '').isEmpty ? 'owner' : get(ownerUsernameKey)!;

  set ownerUsername(String value) => set(ownerUsernameKey, value);

  /// Trash auto-purge retention in days. 30 by default, 0 = keep forever.
  int get trashRetentionDays {
    final raw = get(trashRetentionDaysKey);
    if (raw == null) return 30;
    return int.tryParse(raw) ?? 30;
  }

  set trashRetentionDays(int value) =>
      set(trashRetentionDaysKey, '$value');

  /// Per-upload quota: rejects uploads that would push vault usage above this
  /// many bytes. 0 (default) = unlimited.
  int get deviceQuotaBytes {
    final raw = get(deviceQuotaBytesKey);
    if (raw == null) return 0;
    return int.tryParse(raw) ?? 0;
  }

  set deviceQuotaBytes(int value) => set(deviceQuotaBytesKey, '$value');

  String? get tlsCertPath => get(tlsCertPathKey);
  String? get tlsKeyPath => get(tlsKeyPathKey);

  /// Monotonic revision bumped on every mutation; clients poll it for sync.
  int get dataVersion => int.tryParse(get(dataVersionKey) ?? '0') ?? 0;

  int bumpDataVersion() {
    final next = dataVersion + 1;
    set(dataVersionKey, '$next');
    return next;
  }
  set tlsPaths(({String cert, String key})? value) {
    if (value == null) {
      _setOrDelete(tlsCertPathKey, null);
      _setOrDelete(tlsKeyPathKey, null);
    } else {
      set(tlsCertPathKey, value.cert);
      set(tlsKeyPathKey, value.key);
    }
  }

  void _setOrDelete(String key, String? value) {
    if (value == null) {
      _db.raw.execute('DELETE FROM settings WHERE key = ?', [key]);
    } else {
      set(key, value);
    }
  }
}