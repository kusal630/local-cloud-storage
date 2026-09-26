import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/core/utils/pool_cipher.dart';
import 'package:path/path.dart' as p;

void main() {
  final pairingSecret = List<int>.generate(32, (i) => (i * 7 + 3) % 256);
  final otherSecret = List<int>.generate(32, (i) => (i * 11 + 1) % 256);
  final masterKek = List<int>.generate(32, (i) => (i * 13 + 5) % 256);
  final chunkId = 'c' * 64;
  final aad = 'contrib-1';
  final plaintext = utf8.encode('pooled data cloud chunk payload');

  group('PoolCipher.deriveChunkKey', () {
    test('is deterministic and produces a 32-byte key', () async {
      final k1 = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final k2 = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      expect(k1.length, 32);
      expect(k1, equals(k2));
    });

    test('distinct chunkId yields distinct keys', () async {
      final k1 = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final k2 = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: 'd' * 64,
      );
      expect(k1, isNot(equals(k2)));
    });

    test('distinct pairing secrets yield distinct keys', () async {
      final k1 = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final k2 = await PoolCipher.deriveChunkKey(
        pairingSecret: otherSecret,
        chunkId: chunkId,
      );
      expect(k1, isNot(equals(k2)));
    });

    test('rejects empty inputs', () async {
      await expectLater(
        PoolCipher.deriveChunkKey(pairingSecret: const [], chunkId: chunkId),
        throwsA(isA<PoolCryptoException>()),
      );
      await expectLater(
        PoolCipher.deriveChunkKey(
          pairingSecret: pairingSecret,
          chunkId: '',
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });
  });

  group('PoolCipher.encryptChunk / decryptChunk', () {
    test('round-trips with nonce‖ciphertext‖tag layout', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
        key: key,
        plaintext: plaintext,
        aad: aad,
      );
      expect(blob.length,
          PoolCipher.nonceLength + plaintext.length + PoolCipher.tagLength);
      final out = await PoolCipher.decryptChunk(key: key, data: blob, aad: aad);
      expect(out, equals(plaintext));
    });

    test('round-trips an empty plaintext', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob =
          await PoolCipher.encryptChunk(key: key, plaintext: const [], aad: aad);
      expect(
          blob.length, PoolCipher.nonceLength + PoolCipher.tagLength);
      final out = await PoolCipher.decryptChunk(key: key, data: blob, aad: aad);
      expect(out, isEmpty);
    });

    test('uses a fresh random nonce on every encryption', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final a = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      final b = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      expect(a, isNot(equals(b)));
      final nonceA = a.sublist(0, PoolCipher.nonceLength);
      final nonceB = b.sublist(0, PoolCipher.nonceLength);
      expect(nonceA, isNot(equals(nonceB)));
    });

    test('wrong key fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final wrongKey = await PoolCipher.deriveChunkKey(
        pairingSecret: otherSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      await expectLater(
        PoolCipher.decryptChunk(key: wrongKey, data: blob, aad: aad),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('tampered tag fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      final tampered = List<int>.from(blob);
      tampered[tampered.length - 1] ^= 0x01;
      await expectLater(
        PoolCipher.decryptChunk(key: key, data: tampered, aad: aad),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('tampered ciphertext fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      final tampered = List<int>.from(blob);
      tampered[PoolCipher.nonceLength + 3] ^= 0x80;
      await expectLater(
        PoolCipher.decryptChunk(key: key, data: tampered, aad: aad),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('tampered nonce fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      final tampered = List<int>.from(blob);
      tampered[0] ^= 0x01;
      await expectLater(
        PoolCipher.decryptChunk(key: key, data: tampered, aad: aad),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('AAD mismatch fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      await expectLater(
        PoolCipher.decryptChunk(key: key, data: blob, aad: 'contrib-2'),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('truncated blob fails with PoolCryptoException', () async {
      final key = await PoolCipher.deriveChunkKey(
        pairingSecret: pairingSecret,
        chunkId: chunkId,
      );
      final blob = await PoolCipher.encryptChunk(
          key: key, plaintext: plaintext, aad: aad);
      await expectLater(
        PoolCipher.decryptChunk(
          key: key,
          data: blob.sublist(0, 8),
          aad: aad,
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('rejects keys that are not 32 bytes', () async {
      await expectLater(
        PoolCipher.encryptChunk(
          key: List<int>.filled(16, 1),
          plaintext: plaintext,
          aad: aad,
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });
  });

  group('PoolCipher.wrapSecret / unwrapSecret', () {
    test('round-trips the pairing secret', () async {
      final wrapped = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      expect(wrapped.length, PoolCipher.nonceLength +
          pairingSecret.length +
          PoolCipher.tagLength);
      final out = await PoolCipher.unwrapSecret(
        masterKek: masterKek,
        wrapped: wrapped,
        contributorId: aad,
      );
      expect(out, equals(pairingSecret));
    });

    test('two wraps of the same secret produce different ciphertexts',
        () async {
      final w1 = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      final w2 = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      expect(w1.length, equals(w2.length));
      expect(w1, isNot(equals(w2)));
      // Fresh random nonce per wrap (CONSULT §5.3 fixed-nonce correction).
      final nonce1 = w1.sublist(0, PoolCipher.nonceLength);
      final nonce2 = w2.sublist(0, PoolCipher.nonceLength);
      expect(nonce1, isNot(equals(nonce2)));
      // Both still unwrap to the same secret.
      expect(
        await PoolCipher.unwrapSecret(
            masterKek: masterKek, wrapped: w1, contributorId: aad),
        equals(pairingSecret),
      );
      expect(
        await PoolCipher.unwrapSecret(
            masterKek: masterKek, wrapped: w2, contributorId: aad),
        equals(pairingSecret),
      );
    });

    test('wrong contributor id fails (AAD)', () async {
      final wrapped = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      await expectLater(
        PoolCipher.unwrapSecret(
          masterKek: masterKek,
          wrapped: wrapped,
          contributorId: 'contrib-2',
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('wrong master KEK fails', () async {
      final wrapped = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      await expectLater(
        PoolCipher.unwrapSecret(
          masterKek: otherSecret,
          wrapped: wrapped,
          contributorId: aad,
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('wrap key is domain-separated from chunk keys', () async {
      // Same IKM under the chunk-key HKDF domain must not unlock a wrap
      // produced under the 'contrib-secret-wrap' domain.
      final wrapped = await PoolCipher.wrapSecret(
        masterKek: masterKek,
        secret: pairingSecret,
        contributorId: aad,
      );
      final chunkKey = await PoolCipher.deriveChunkKey(
        pairingSecret: masterKek,
        chunkId: aad,
      );
      await expectLater(
        PoolCipher.unwrapSecret(
          masterKek: chunkKey,
          wrapped: wrapped,
          contributorId: aad,
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('rejects a master KEK that is not 32 bytes', () async {
      await expectLater(
        PoolCipher.wrapSecret(
          masterKek: const [1, 2, 3],
          secret: pairingSecret,
          contributorId: aad,
        ),
        throwsA(isA<PoolCryptoException>()),
      );
    });
  });

  group('PoolCipher.verifyPlaintextSha256', () {
    final data = utf8.encode('content id of this chunk');
    final digest = Cipher.sha256Hex(data);

    test('accepts the correct digest', () {
      expect(PoolCipher.verifyPlaintextSha256(data, digest), isTrue);
    });

    test('rejects a wrong digest', () {
      expect(PoolCipher.verifyPlaintextSha256(data, '0' * 64), isFalse);
      expect(
        PoolCipher.verifyPlaintextSha256(
            utf8.encode('different'), digest),
        isFalse,
      );
    });

    test('rejects non-canonical hex', () {
      expect(PoolCipher.verifyPlaintextSha256(data, digest.toUpperCase()),
          isFalse);
      expect(PoolCipher.verifyPlaintextSha256(data, digest.substring(0, 63)),
          isFalse);
      expect(PoolCipher.verifyPlaintextSha256(data, 'zz${'0' * 62}'),
          isFalse);
    });
  });

  group('PoolKeyStore', () {
    late Directory vaultDir;

    setUp(() {
      vaultDir = Directory.systemTemp.createTempSync('pool_kek_test');
    });

    tearDown(() {
      if (vaultDir.existsSync()) {
        vaultDir.deleteSync(recursive: true);
      }
    });

    test('FilePoolKeyStore generates a 32-byte KEK and reloads it', () async {
      final store = FilePoolKeyStore(vaultDir: vaultDir);
      final kek = await store.getMasterKek();
      expect(kek.length, 32);
      expect(await store.kekFile.exists(), isTrue);
      final reloaded = await FilePoolKeyStore(vaultDir: vaultDir)
          .getMasterKek();
      expect(reloaded, equals(kek));
    });

    test('FilePoolKeyStore locks dir and file to owner-only 0700', () async {
      final store = FilePoolKeyStore(vaultDir: vaultDir);
      await store.getMasterKek();
      if (Platform.isWindows) return;
      expect(FileStat.statSync(vaultDir.path).mode & 0x1FF, equals(0x1C0));
      expect(
          FileStat.statSync(store.kekFile.path).mode & 0x1FF, equals(0x1C0));
    });

    test('FilePoolKeyStore rejects a corrupt stored KEK', () async {
      final store = FilePoolKeyStore(vaultDir: vaultDir);
      await store.kekFile.writeAsBytes(const [1, 2, 3]);
      await expectLater(
        store.getMasterKek(),
        throwsA(isA<PoolCryptoException>()),
      );
    });

    test('standard store serves a stable key (file fallback in tests)',
        () async {
      final store = PoolKeyStore.standard(vaultDir: vaultDir);
      final kek = await store.getMasterKek();
      expect(kek.length, 32);
      expect(await store.getMasterKek(), equals(kek));
      // Unit tests have no platform keystore, so the default store must have
      // fallen back to `<vaultDir>/pool_kek`.
      expect(File(p.join(vaultDir.path, 'pool_kek')).existsSync(), isTrue);
    });
  });
}
