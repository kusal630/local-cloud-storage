import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/client/services/backup_service.dart';
import 'package:localvault/core/utils/file_kinds.dart';

void main() {
  test('categoryOf classifies by mime first', () {
    expect(FileKinds.categoryOf('x.bin', 'image/png'), FileKinds.images);
    expect(FileKinds.categoryOf('x.bin', 'video/mp4'), FileKinds.video);
    expect(FileKinds.categoryOf('x.bin', 'audio/mpeg'), FileKinds.audio);
  });

  test('categoryOf falls back to extension', () {
    expect(FileKinds.categoryOf('a.jpg', null), FileKinds.images);
    expect(FileKinds.categoryOf('a.mkv', null), FileKinds.video);
    expect(FileKinds.categoryOf('a.mp3', null), FileKinds.audio);
    expect(FileKinds.categoryOf('a.pdf', null), FileKinds.docs);
    expect(FileKinds.categoryOf('a.xlsx', null), FileKinds.docs);
    expect(FileKinds.categoryOf('a.zip', null), FileKinds.archives);
    expect(FileKinds.categoryOf('a.unknown', null), FileKinds.other);
    expect(FileKinds.categoryOf('noext', null), FileKinds.other);
  });

  test('quotaError allows unlimited and blocks over-quota', () {
    expect(
      FileKinds.quotaError(
          quotaBytes: 0, currentBytes: 999, incomingBytes: 999),
      isNull,
    );
    expect(
      FileKinds.quotaError(
          quotaBytes: 100, currentBytes: 60, incomingBytes: 40),
      isNull,
    );
    expect(
      FileKinds.quotaError(
          quotaBytes: 100, currentBytes: 60, incomingBytes: 41),
      isNotNull,
    );
  });

  test('beacon encode/decode round-trips', () {
    final raw = FileKinds.beaconEncode(
      deviceName: 'My Node',
      host: '192.168.1.5',
      port: 8484,
      secure: false,
    );
    final decoded = FileKinds.beaconDecode(raw);
    expect(decoded, isNotNull);
    expect(decoded!.deviceName, 'My Node');
    expect(decoded.host, '192.168.1.5');
    expect(decoded.port, 8484);
    expect(decoded.secure, isFalse);
  });

  test('beaconDecode rejects malformed payloads', () {
    expect(FileKinds.beaconDecode('garbage'), isNull);
    expect(FileKinds.beaconDecode('localvault-v1|a||0|http'), isNull);
    expect(
        FileKinds.beaconDecode('localvault-v1|a|1.2.3.4|99999|http'),
        isNull);
    expect(FileKinds.beaconDecode('localvault-v1|||8484|http'), isNull);
  });

  test('username rules accept sane names and reject the rest', () {
    expect(FileKinds.isValidUsername('kusal'), isTrue);
    expect(FileKinds.isValidUsername('ku-sal_99.x'), isTrue);
    expect(FileKinds.isValidUsername('ab'), isFalse);
    expect(FileKinds.isValidUsername('has space'), isFalse);
    expect(FileKinds.isValidUsername('UPPER'), isTrue);
    expect(FileKinds.sanitizeUsername('  Ku Sal! '), 'kusal');
  });

  test('backup shouldSkip filters junk and huge files', () {
    expect(BackupService.shouldSkip('IMG_001.jpg', 1024), isFalse);
    expect(BackupService.shouldSkip('.nomedia', 10), isTrue);
    expect(BackupService.shouldSkip('a.tmp', 10), isTrue);
    expect(BackupService.shouldSkip('a.jpg', 0), isTrue);
    expect(BackupService.shouldSkip(
        'a.mp4', BackupService.maxFileBytes + 1), isTrue);
  });
}
