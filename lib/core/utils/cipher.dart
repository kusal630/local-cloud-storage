import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:cryptography/cryptography.dart';

import '../errors/app_exceptions.dart';

/// Cryptographic helpers: hashing, random token generation and constant time
/// comparison helpers.
abstract class Cipher {
  Cipher._();

  static final Random _random = Random.secure();

  static const int _defaultHashIterations = 3;
  static const int _defaultHashMemoryKiB = 32 * 1024;
  static const int _defaultHashParallelism = 1;
  static const int _saltLength = 16;

  /// Pure-Dart Argon2id password hasher.
  static final Argon2id _argon2 = Argon2id(
    iterations: _defaultHashIterations,
    memory: _defaultHashMemoryKiB,
    parallelism: _defaultHashParallelism,
    hashLength: 32,
  );

  /// Returns a secure random hex string with [bytes] bytes of entropy.
  static String randomHex(int bytes) {
    final data = Uint8List(bytes);
    for (var i = 0; i < bytes; i++) {
      data[i] = _random.nextInt(256);
    }
    return _bytesToHex(data);
  }

  /// Returns a cryptographically random n-digit numeric code.
  static String randomDigits(int length) {
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      buffer.write(_random.nextInt(10));
    }
    return buffer.toString();
  }

  /// SHA-256 of [data] as lowercase hex.
  static String sha256Hex(List<int> data) =>
      _bytesToHex(c.sha256.convert(data).bytes);

  /// SHA-256 of a string (UTF-8 encoded) as lowercase hex.
  static String sha256String(String value) => sha256Hex(utf8.encode(value));

  /// Computes SHA-256 of a file without loading it entirely into memory.
  static Future<String> sha256File(File file) async {
    final hash = Sha256();
    final sink = hash.newHashSink();
    try {
      await for (final chunk in file.openRead()) {
        sink.add(chunk);
      }
    } finally {
      sink.close();
    }
    final digest = await sink.hash();
    return _bytesToHex(digest.bytes);
  }

  /// Hashes a password with Argon2id and a random salt.
  ///
  /// The encoded format is `argon2id$<salt-hex>$<hash-hex>`.
  static Future<String> hashPassword(String password) async {
    final salt = Uint8List(_saltLength);
    for (var i = 0; i < salt.length; i++) {
      salt[i] = _random.nextInt(256);
    }
    final hash = await _argon2.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    return 'argon2id\$${_bytesToHex(salt)}\$${_bytesToHex(await hash.extractBytes())}';
  }

  /// Verifies a password against an encoded Argon2id hash.
  static Future<bool> verifyPassword(String password, String encoded) async {
    try {
      final parts = encoded.split(r'$');
      if (parts.length != 3 || parts[0] != 'argon2id') {
        return false;
      }
      final salt = _fromHex(parts[1]);
      final expected = _fromHex(parts[2]);
      final hash = await _argon2.deriveKey(
        secretKey: SecretKey(utf8.encode(password)),
        nonce: salt,
      );
      final actual = await hash.extractBytes();
      return _constantTimeEquals(actual, expected);
    } on FormatException {
      return false;
    }
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Encodes bytes as lowercase hex.
  static String _bytesToHex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Decodes lowercase hex back into bytes.
  static Uint8List _fromHex(String hex) {
    if (hex.length.isOdd) {
      throw const FormatException('Odd length hex string');
    }
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final hi = _hexDigit(hex.codeUnitAt(i * 2));
      final lo = _hexDigit(hex.codeUnitAt(i * 2 + 1));
      out[i] = (hi << 4) | lo;
    }
    return out;
  }

  static int _hexDigit(int code) {
    if (code >= 0x30 && code <= 0x39) return code - 0x30;
    if (code >= 0x61 && code <= 0x66) return code - 0x37;
    throw const FormatException('Invalid hex digit');
  }

  /// Validates a SHA-256 hex digest string.
  static void validateSha256(String checksum) {
    if (checksum.length != 64) {
      throw const ValidationException('Checksum must be a 64 char hex string');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      throw const ValidationException('Checksum must be lowercase hex');
    }
  }
}