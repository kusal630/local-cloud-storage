import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart'
    show AesGcm, Hkdf, Hmac, Mac, SecretBox, SecretBoxAuthenticationError, SecretKey;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../errors/app_exceptions.dart';
import 'cipher.dart';

final Random _secureRandom = Random.secure();

/// [length] cryptographically secure random bytes from [random].
Uint8List _secureBytes(Random random, int length) {
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = random.nextInt(256);
  }
  return out;
}

/// Best-effort owner-only (`0700`) permissions, mirroring the vault dir
/// lockdown in `Vault._ensureDirs` (POSIX only; Windows ACLs are out of
/// scope for this slice).
Future<void> _chmodOwnerOnly(String path) async {
  if (!Platform.isLinux && !Platform.isMacOS && !Platform.isAndroid) return;
  try {
    await Process.run('chmod', ['700', path]);
  } catch (_) {
    // Best effort — same policy as the vault directory lockdown.
  }
}

/// Typed failure raised by [PoolCipher] and [PoolKeyStore].
///
/// Raised on GCM tag mismatch, malformed encrypted blobs, wrong key sizes
/// and corrupt stored key material — never thrown as a bare string.
class PoolCryptoException extends AppException {
  const PoolCryptoException(super.message, {super.cause});
}

/// Chunk-level cryptography for the v2.4.0 Pooled Data Cloud
/// (SLICE POOL-CRYPTO — spec: `RESEARCH/CONSULT.md` §5).
///
/// Every encrypted blob (chunk or wrapped secret) uses the layout:
///
/// ```text
/// [12 B random nonce][ciphertext][16 B GCM tag]
/// ```
///
/// Domain separation (the §5 pitfall): per-chunk keys are
/// `HKDF-SHA256(ikm = pairingSecret, salt = 'lv-pool-v1',
/// info = 'chunk-key' || chunkId)` while the secret wrap key is
/// `HKDF-SHA256(ikm = masterKek, salt = 'lv-pool-v1',
/// info = 'contrib-secret-wrap')` — the two derivations never share an
/// `info` label, nor an IKM.
abstract class PoolCipher {
  PoolCipher._();

  /// HKDF salt for every pool key derivation (CONSULT §5).
  static const String hkdfSalt = 'lv-pool-v1';

  /// HKDF `info` prefix for per-chunk keys: `'chunk-key' || chunkId`.
  static const String _chunkKeyInfoPrefix = 'chunk-key';

  /// HKDF `info` label for the contributor-secret wrap key. Deliberately
  /// distinct from the chunk-key label — HKDF domain separation.
  static const String _wrapKeyInfo = 'contrib-secret-wrap';

  /// AES-256 / master KEK size in bytes.
  static const int keyLength = 32;

  /// 96-bit random GCM nonce size (CONSULT §5.2).
  static const int nonceLength = 12;

  /// 16-byte GCM tag size.
  static const int tagLength = 16;

  /// AES-256-GCM. `AesGcm.with256bits()` is the `cryptography` ^2.9.0
  /// spelling of `AesGcm.aes256gcm()` (later versions add that alias).
  static final AesGcm _aes = AesGcm.with256bits();

  static final Hkdf _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: keyLength);

  /// `K_chunk = HKDF-SHA256(ikm = pairingSecret, salt = 'lv-pool-v1',
  /// info = 'chunk-key' || chunkId)` — 32 bytes (CONSULT §5.1).
  ///
  /// Both the host and the owning contributor can derive it; nobody else.
  static Future<Uint8List> deriveChunkKey({
    required List<int> pairingSecret,
    required String chunkId,
  }) async {
    if (pairingSecret.isEmpty) {
      throw const PoolCryptoException('pairingSecret must not be empty');
    }
    if (chunkId.isEmpty) {
      throw const PoolCryptoException('chunkId must not be empty');
    }
    return _deriveKey(ikm: pairingSecret, info: '$_chunkKeyInfoPrefix$chunkId');
  }

  /// Encrypts [plaintext] with AES-256-GCM under [key] (exactly 32 bytes).
  ///
  /// Returns `12 B nonce ‖ ciphertext ‖ 16 B tag` (CONSULT §5.2) with a
  /// fresh `Random.secure` nonce on every call — never a fixed nonce.
  ///
  /// [aad] is authenticated but not encrypted. For chunks it must be
  /// `chunkId ‖ contributorId ‖ epoch` (CONSULT §5.2; chunk ids are
  /// fixed-length hex per §6, so the concatenation is unambiguous).
  static Future<Uint8List> encryptChunk({
    required List<int> key,
    required List<int> plaintext,
    required String aad,
  }) async {
    _checkKeyLength(key, 'key');
    _checkAad(aad);
    final box = await _aes.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _newNonce(),
      aad: utf8.encode(aad),
    );
    return _pack(box.nonce, box.cipherText, box.mac.bytes);
  }

  /// Decrypts a blob produced by [encryptChunk] (or [unwrapSecret]), and
  /// verifies the GCM tag against [aad] before returning the plaintext.
  ///
  /// Throws [PoolCryptoException] on tag mismatch (wrong key, tampered
  /// bytes or a different AAD) and on malformed input.
  static Future<Uint8List> decryptChunk({
    required List<int> key,
    required List<int> data,
    required String aad,
  }) async {
    _checkKeyLength(key, 'key');
    _checkAad(aad);
    final box = _unpack(data);
    try {
      return Uint8List.fromList(await _aes.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: utf8.encode(aad),
      ));
    } on SecretBoxAuthenticationError catch (e) {
      throw PoolCryptoException(
        'GCM tag verification failed (wrong key, tampered data or AAD mismatch)',
        cause: e,
      );
    }
  }

  /// Wraps a contributor pairing secret under the master KEK so no
  /// plaintext secret ever rests on the host (CONSULT §5.3).
  ///
  /// wrapKey = `HKDF-SHA256(ikm = masterKek, salt = 'lv-pool-v1',
  /// info = 'contrib-secret-wrap')`, then AES-256-GCM with a **fresh random
  /// 12-byte nonce on every wrap** (never a fixed nonce — §5 explicitly
  /// corrects that) and AAD = [contributorId].
  ///
  /// Returns `12 B nonce ‖ ciphertext ‖ 16 B tag`.
  static Future<Uint8List> wrapSecret({
    required List<int> masterKek,
    required List<int> secret,
    required String contributorId,
  }) async {
    _checkKeyLength(masterKek, 'masterKek');
    if (secret.isEmpty) {
      throw const PoolCryptoException('secret must not be empty');
    }
    if (contributorId.isEmpty) {
      throw const PoolCryptoException('contributorId must not be empty');
    }
    final wrapKey = await _deriveKey(ikm: masterKek, info: _wrapKeyInfo);
    return encryptChunk(key: wrapKey, plaintext: secret, aad: contributorId);
  }

  /// Inverse of [wrapSecret]: unwraps the pairing secret for
  /// [contributorId] and verifies the GCM tag.
  ///
  /// Throws [PoolCryptoException] on tag mismatch (wrong master KEK, wrong
  /// contributor id or tampered bytes).
  static Future<Uint8List> unwrapSecret({
    required List<int> masterKek,
    required List<int> wrapped,
    required String contributorId,
  }) async {
    _checkKeyLength(masterKek, 'masterKek');
    if (contributorId.isEmpty) {
      throw const PoolCryptoException('contributorId must not be empty');
    }
    final wrapKey = await _deriveKey(ikm: masterKek, info: _wrapKeyInfo);
    return decryptChunk(key: wrapKey, data: wrapped, aad: contributorId);
  }

  /// Returns `true` when SHA-256 of [plaintext] equals [expectedHex]
  /// (exactly 64 lowercase hex chars), compared in constant time.
  ///
  /// The plaintext SHA-256 is the pool's content id (CONSULT §6 control 1):
  /// GCM provides confidentiality/integrity, this provides the dedup key.
  static bool verifyPlaintextSha256(List<int> plaintext, String expectedHex) {
    if (expectedHex.length != 64 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(expectedHex)) {
      return false;
    }
    final actualHex = Cipher.sha256Hex(plaintext);
    return Cipher.constantTimeEquals(
      utf8.encode(actualHex),
      utf8.encode(expectedHex),
    );
  }

  /// Shared HKDF step: `HKDF-SHA256(ikm, salt = 'lv-pool-v1', info)`.
  static Future<Uint8List> _deriveKey({
    required List<int> ikm,
    required String info,
  }) async {
    final derived = await _kdf.deriveKey(
      secretKey: SecretKey(ikm),
      nonce: utf8.encode(hkdfSalt),
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await derived.extractBytes());
  }

  static Uint8List _newNonce() => _secureBytes(_secureRandom, nonceLength);

  static void _checkKeyLength(List<int> key, String name) {
    if (key.length != keyLength) {
      throw PoolCryptoException(
        '$name must be $keyLength bytes (got ${key.length})',
      );
    }
  }

  static void _checkAad(String aad) {
    if (aad.isEmpty) {
      throw const PoolCryptoException('aad must not be empty');
    }
  }

  /// `nonce ‖ ciphertext ‖ tag`.
  static Uint8List _pack(List<int> nonce, List<int> cipherText, List<int> tag) {
    final out = Uint8List(nonce.length + cipherText.length + tag.length);
    out.setAll(0, nonce);
    out.setAll(nonce.length, cipherText);
    out.setAll(nonce.length + cipherText.length, tag);
    return out;
  }

  /// Parses `nonce ‖ ciphertext ‖ tag` back into a [SecretBox].
  static SecretBox _unpack(List<int> data) {
    if (data.length < nonceLength + tagLength) {
      throw PoolCryptoException(
        'Encrypted blob shorter than ${nonceLength + tagLength} bytes '
        '(got ${data.length})',
      );
    }
    final cut = data.length - tagLength;
    return SecretBox(
      Uint8List.fromList(data.sublist(nonceLength, cut)),
      nonce: Uint8List.fromList(data.sublist(0, nonceLength)),
      mac: Mac(Uint8List.fromList(data.sublist(cut))),
    );
  }
}

/// Source of the 32-byte master KEK that wraps contributor pairing secrets
/// at rest (CONSULT §5.3).
abstract class PoolKeyStore {
  const PoolKeyStore();

  /// Returns the master KEK, generating it on first use.
  Future<List<int>> getMasterKek();

  /// Default store: the platform keystore via `flutter_secure_storage`
  /// (present in pubspec), falling back to an owner-only
  /// `<vaultDir>/pool_kek` file when no platform keystore is available
  /// (headless Linux without libsecret, unit tests without a registered
  /// plugin).
  ///
  /// [vaultDir] is the `.localvault` directory of the active vault.
  factory PoolKeyStore.standard({
    required Directory vaultDir,
    FlutterSecureStorage? storage,
  }) {
    return _StandardPoolKeyStore(vaultDir: vaultDir, storage: storage);
  }
}

/// Master KEK held in the platform keystore (Android Keystore / Keychain /
/// DPAPI / libsecret) through `flutter_secure_storage`, base64-encoded under
/// a fixed key name.
///
/// Plugin-level failures (missing platform plugin, `PlatformException`s)
/// propagate untouched so callers can decide whether to fall back; only
/// *corrupt stored material* raises [PoolCryptoException], because silently
/// re-keying there would strand every already-wrapped pairing secret.
class SecureStoragePoolKeyStore extends PoolKeyStore {
  SecureStoragePoolKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// Secure-storage entry holding the base64 master KEK.
  static const String storageKeyName = 'pool_kek';

  final FlutterSecureStorage _storage;

  @override
  Future<List<int>> getMasterKek() async {
    final raw = await _storage.read(key: storageKeyName);
    if (raw == null) {
      // First run: generate a 32-byte KEK with Random.secure and persist it.
      final fresh = _secureBytes(_secureRandom, PoolCipher.keyLength);
      await _storage.write(key: storageKeyName, value: base64Encode(fresh));
      return fresh;
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(raw);
    } on FormatException catch (e) {
      throw PoolCryptoException('Stored master KEK is not valid base64',
          cause: e);
    }
    if (bytes.length != PoolCipher.keyLength) {
      throw PoolCryptoException(
        'Stored master KEK must be ${PoolCipher.keyLength} bytes '
        '(got ${bytes.length})',
      );
    }
    return bytes;
  }
}

/// Master KEK kept in `<vaultDir>/pool_kek` — an owner-only `0700` file
/// inside the owner-only `0700` vault dir (`.localvault/pool_kek`), the
/// CONSULT §5.3 fallback for hosts with no platform keystore.
///
/// Assumes the single host process (same assumption as the SQLite vault);
/// a first-run multi-process race is resolved by "last writer wins".
class FilePoolKeyStore extends PoolKeyStore {
  FilePoolKeyStore({required Directory vaultDir})
      : _vaultDir = vaultDir,
        kekFile = File(p.join(vaultDir.path, kekFileName));

  /// File name inside the vault dir → `<vaultDir>/pool_kek`.
  static const String kekFileName = 'pool_kek';

  final Directory _vaultDir;

  /// The raw KEK file.
  final File kekFile;

  @override
  Future<List<int>> getMasterKek() async {
    await _vaultDir.create(recursive: true);
    await _chmodOwnerOnly(_vaultDir.path);
    if (await kekFile.exists()) {
      return _readKek();
    }
    final fresh = _secureBytes(_secureRandom, PoolCipher.keyLength);
    await kekFile.writeAsBytes(fresh, flush: true);
    await _chmodOwnerOnly(kekFile.path);
    return fresh;
  }

  Future<List<int>> _readKek() async {
    final List<int> bytes;
    try {
      bytes = await kekFile.readAsBytes();
    } on FileSystemException catch (e) {
      throw PoolCryptoException('Cannot read ${kekFile.path}', cause: e);
    }
    if (bytes.length != PoolCipher.keyLength) {
      throw PoolCryptoException(
        'Stored master KEK must be ${PoolCipher.keyLength} bytes '
        '(got ${bytes.length})',
      );
    }
    return bytes;
  }
}

/// Default composite store: platform keystore first, `pool_kek` file as the
/// fallback when no platform keystore is reachable.
class _StandardPoolKeyStore extends PoolKeyStore {
  _StandardPoolKeyStore({
    required Directory vaultDir,
    FlutterSecureStorage? storage,
  })  : _secure = SecureStoragePoolKeyStore(storage: storage),
        _file = FilePoolKeyStore(vaultDir: vaultDir);

  final SecureStoragePoolKeyStore _secure;
  final FilePoolKeyStore _file;

  @override
  Future<List<int>> getMasterKek() async {
    try {
      return await _secure.getMasterKek();
    } on PoolCryptoException {
      // Corrupt stored KEK: never silently fall back and re-key — that
      // would strand every already-wrapped pairing secret.
      rethrow;
    } catch (_) {
      // Platform keystore unavailable (headless Linux, unit test env) →
      // 0700 vault file.
      return _file.getMasterKek();
    }
  }
}
