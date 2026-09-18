/// File category helpers shared by the storage breakdown, icons and tests.
///
/// No Flutter imports: pure Dart so unit tests stay fast.
abstract class FileKinds {
  static const String images = 'images';
  static const String video = 'video';
  static const String audio = 'audio';
  static const String docs = 'docs';
  static const String archives = 'archives';
  static const String other = 'other';

  static const List<String> all = [
    images,
    video,
    audio,
    docs,
    archives,
    other,
  ];

  /// Category for a file with [name] and optional [mime].
  static String categoryOf(String name, String? mime) {
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('image/')) return images;
    if (m.startsWith('video/')) return video;
    if (m.startsWith('audio/')) return audio;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (const {'jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp', 'svg'}
        .contains(ext)) {
      return images;
    }
    if (const {'mp4', 'mkv', 'mov', 'avi', 'webm'}.contains(ext)) {
      return video;
    }
    if (const {'mp3', 'wav', 'flac', 'ogg', 'm4a'}.contains(ext)) {
      return audio;
    }
    if (const {
      'pdf',
      'doc',
      'docx',
      'txt',
      'md',
      'rtf',
      'xls',
      'xlsx',
      'csv',
      'ppt',
      'pptx'
    }.contains(ext)) {
      return docs;
    }
    if (const {'zip', 'rar', '7z', 'tar', 'gz'}.contains(ext)) {
      return archives;
    }
    return other;
  }

  /// Returns an error string when [incomingBytes] would exceed [quotaBytes].
  /// Null quota (or <= 0) means unlimited. Null return means allowed.
  static String? quotaError({
    required int quotaBytes,
    required int currentBytes,
    required int incomingBytes,
  }) {
    if (quotaBytes <= 0) return null;
    if (currentBytes + incomingBytes > quotaBytes) {
      return 'Quota exceeded.';
    }
    return null;
  }

  /// Encodes a LAN discovery beacon payload.
  static String beaconEncode({
    required String deviceName,
    required String host,
    required int port,
    required bool secure,
  }) =>
      'localvault-v1|$deviceName|$host|$port|${secure ? 'https' : 'http'}';

  /// Decodes a beacon payload. Returns null when malformed.
  static ({String deviceName, String host, int port, bool secure})?
      beaconDecode(String raw) {
    final parts = raw.split('|');
    if (parts.length != 5 || parts[0] != 'localvault-v1') return null;
    final port = int.tryParse(parts[3]);
    if (port == null || port <= 0 || port > 65535) return null;
    if (parts[2].isEmpty) return null;
    return (
      deviceName: parts[1].isEmpty ? 'Storage Node' : parts[1],
      host: parts[2],
      port: port,
      secure: parts[4] == 'https',
    );
  }
}
