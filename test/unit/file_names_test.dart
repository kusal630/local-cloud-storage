import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/file_names.dart';

void main() {
  group('FileNames.validate', () {
    test('rejects empty name', () {
      expect(FileNames.validate(''), isNotNull);
    });
    test('rejects . and ..', () {
      expect(FileNames.validate('.'), isNotNull);
      expect(FileNames.validate('..'), isNotNull);
    });
    test('rejects path traversal', () {
      expect(FileNames.validate('../secret'), isNotNull);
      expect(FileNames.validate('a/b'), isNotNull);
      expect(FileNames.validate(r'a\b'), isNotNull);
    });
    test('rejects control characters', () {
      expect(FileNames.validate('file\x00name'), isNotNull);
      expect(FileNames.validate('file\nname'), isNotNull);
    });
    test('rejects names longer than 255', () {
      expect(FileNames.validate('a' * 256), isNotNull);
    });
    test('accepts valid names', () {
      expect(FileNames.validate('hello.txt'), isNull);
      expect(FileNames.validate('my file (1).pdf'), isNull);
      expect(FileNames.validate('a'), isNull);
    });
  });

  group('FileNames.sanitize', () {
    test('replaces slashes with underscores', () {
      expect(FileNames.sanitize('a/b\\c'), 'a_b_c');
    });
    test('removes control characters', () {
      expect(FileNames.sanitize('a\x00b'), 'ab');
    });
    test('trims whitespace', () {
      expect(FileNames.sanitize('  hi  '), 'hi');
    });
    test('throws on invalid result', () {
      expect(() => FileNames.sanitize('..'), throwsA(isA<Exception>()));
    });
  });

  group('FileNames.numberedVariant', () {
    test('appends (n) to file without extension', () {
      expect(FileNames.numberedVariant('readme', 1), 'readme (1)');
    });
    test('appends (n) before extension', () {
      expect(FileNames.numberedVariant('file.txt', 2), 'file (2).txt');
    });
    test('handles dot-files', () {
      expect(FileNames.numberedVariant('.gitignore', 3), '.gitignore (3)');
    });
  });
}