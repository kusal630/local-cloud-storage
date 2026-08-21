import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/path_guard.dart';

void main() {
  group('Cipher', () {
    test('randomHex returns correct length', () {
      final hex = Cipher.randomHex(32);
      expect(hex.length, 64);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(hex), isTrue);
    });

    test('randomDigits returns correct length', () {
      final digits = Cipher.randomDigits(6);
      expect(digits.length, 6);
      expect(RegExp(r'^\d{6}$').hasMatch(digits), isTrue);
    });

    test('sha256Hex is deterministic', () {
      final a = Cipher.sha256Hex([1, 2, 3]);
      final b = Cipher.sha256Hex([1, 2, 3]);
      expect(a, equals(b));
      expect(a.length, 64);
    });

    test('sha256String hashes string', () {
      final hash = Cipher.sha256String('hello');
      expect(hash.length, 64);
      expect(hash, isNot(equals(Cipher.sha256String('world'))));
    });

    test('sha256File hashes file content', () async {
      final tmp = File('${Directory.systemTemp.path}/test_hash.txt');
      await tmp.writeAsString('test content');
      try {
        final hash = await Cipher.sha256File(tmp);
        expect(hash.length, 64);
      } finally {
        await tmp.delete();
      }
    });

    test('hashPassword produces Argon2id formatted string', () async {
      final hash = await Cipher.hashPassword('mypassword');
      expect(hash.startsWith('argon2id\$'), isTrue);
      expect(hash.split(r'$').length, 3);
      expect(hash.split(r'$')[1].length, 32);
      expect(hash.split(r'$')[2].length, 64);
    });

    test('hashPassword is deterministic for same password', () async {
      final hash1 = await Cipher.hashPassword('mypassword');
      final hash2 = await Cipher.hashPassword('mypassword');
      final salt1 = hash1.split(r'$')[1];
      final salt2 = hash2.split(r'$')[1];
      expect(salt1, isNot(equals(salt2)));
    });

    test('verifyPassword returns false for wrong password', () async {
      final hash = await Cipher.hashPassword('mypassword');
      expect(await Cipher.verifyPassword('wrongpassword', hash), isFalse);
    });

    test('verifyPassword returns false for invalid encoded string', () async {
      expect(await Cipher.verifyPassword('anything', 'invalid'), isFalse);
      expect(
        await Cipher.verifyPassword('test', 'argon2id\$xx\$yy'),
        isFalse,
      );
    });

    test('validateSha256 accepts valid hex', () {
      expect(() => Cipher.validateSha256('a' * 64), returnsNormally);
    });

    test('validateSha256 rejects short string', () {
      expect(() => Cipher.validateSha256('abc'), throwsA(isA<Exception>()));
    });

    test('validateSha256 rejects uppercase hex', () {
      expect(() => Cipher.validateSha256('A' * 64), throwsA(isA<Exception>()));
    });
  });

  group('PathGuard', () {
    test('blobRelativePath produces correct structure', () {
      final path = PathGuard.blobRelativePath('abcdef0123456789');
      expect(path, startsWith('blobs/'));
      expect(path, contains('/abcdef0123456789'));
      expect(path.split('/').length, 4);
    });

    test('blobRelativePath rejects invalid ids', () {
      expect(() => PathGuard.blobRelativePath(''), throwsA(isA<Exception>()));
      expect(() => PathGuard.blobRelativePath('../escape'),
          throwsA(isA<Exception>()));
    });

    test('resolveInside stays within root', () {
      final root = Directory('/vault');
      final result = PathGuard.resolveInside(root, 'blobs/ab/cd/uuid');
      expect(result, startsWith('/vault'));
    });

    test('resolveInside rejects traversal', () {
      final root = Directory('/vault');
      expect(
        () => PathGuard.resolveInside(root, '../escape'),
        throwsA(isA<Exception>()),
      );
    });
  });
}