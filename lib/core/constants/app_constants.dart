/// Global application constants.
abstract class AppConstants {
  AppConstants._();

  static const String appName = 'LocalVault';
  static const String appVersion = '1.0.0';

  /// Default HTTP port used by Host Mode.
  static const int defaultPort = 8484;

  /// Default chunk size for chunked uploads (5 MB).
  static const int uploadChunkSize = 5 * 1024 * 1024;

  /// Lifetime of a short-lived access token.
  static const Duration accessTokenLifetime = Duration(minutes: 15);

  /// Lifetime of a refresh token.
  static const Duration refreshTokenLifetime = Duration(days: 30);

  /// Lifetime of a pairing code.
  static const Duration pairingCodeLifetime = Duration(minutes: 5);

  /// Pairing codes are always 6 digits.
  static const int pairingCodeLength = 6;

  /// Maximum login attempts per minute per IP.
  static const int maxLoginAttemptsPerMinute = 10;

  /// Maximum pairing attempts per minute per IP.
  static const int maxPairingAttemptsPerMinute = 10;

  /// Maximum pairing codes issued per minute per device.
  static const int maxPairingIssuesPerMinute = 5;

  /// Hidden vault directory created inside the selected storage.
  static const String vaultDirName = '.localvault';

  static const String blobsDirName = 'blobs';
  static const String tmpDirName = 'tmp';
  static const String thumbsDirName = 'thumbs';
  static const String logsDirName = 'logs';
  static const String dbFileName = 'db.sqlite';

  /// Stable id of the virtual root folder.
  static const String rootFolderId = 'root';

  /// Maximum allowed length of a sanitized file name.
  static const int maxNameLength = 255;

  /// API prefix for all REST endpoints.
  static const String apiPrefix = '/api/v1';

  /// In-memory log buffer capacity shown in the host logs screen.
  static const int logBufferCapacity = 1000;
}