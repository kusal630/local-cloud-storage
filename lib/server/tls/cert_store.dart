import 'dart:convert';
import 'dart:io';

import 'package:basic_utils/basic_utils.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/logging/app_logger.dart';
import '../../data/datasources/vault.dart';

/// Manages the host's TLS certificate.
///
/// Default is automatic: a 2048-bit RSA self-signed certificate is generated
/// once per vault (valid 825 days) and clients pin its SHA-256 fingerprint
/// (delivered via QR or a verify-on-first-use dialog). Users may override
/// with their own PEM pair via Host Settings; clearing both falls back to
/// plain HTTP.
abstract class CertStore {
  static const String dirName = 'tls';
  static const String certFile = 'cert.pem';
  static const String keyFile = 'key.pem';

  /// Ensures a usable identity. Returns null when TLS is disabled (user
  /// cleared both paths) → caller serves plain HTTP.
  static Future<({String certPath, String keyPath, String fingerprint})?>
      ensure(Vault vault) async {
    final customCert = vault.settings.tlsCertPath ?? '';
    final customKey = vault.settings.tlsKeyPath ?? '';
    if (customCert.isNotEmpty || customKey.isNotEmpty) {
      if (customCert.isEmpty || customKey.isEmpty) return null;
      final certPem = await File(customCert).readAsString();
      return (
        certPath: customCert,
        keyPath: customKey,
        fingerprint: fingerprintOfCertPem(certPem),
      );
    }
    final dir = Directory(p.join(vault.vaultDir.path, dirName));
    await dir.create(recursive: true);
    final certPath = p.join(dir.path, certFile);
    final keyPath = p.join(dir.path, keyFile);
    final certFile_ = File(certPath);
    final keyFile_ = File(keyPath);
    if (!await certFile_.exists() || !await keyFile_.exists()) {
      await _generate(certFile_.path, keyFile_.path);
    }
    final pem = await certFile_.readAsString();
    return (
      certPath: certPath,
      keyPath: keyPath,
      fingerprint: fingerprintOfCertPem(pem),
    );
  }

  static Future<void> _generate(String certPath, String keyPath) async {
    logInfo('Generating self-signed TLS certificate…');
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final priv = pair.privateKey as RSAPrivateKey;
    final pub = pair.publicKey as RSAPublicKey;
    final sans = <String>['DNS:localhost', 'IP:127.0.0.1'];
    try {
      final ifaces = await NetworkInterface.list();
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            sans.add('IP:${addr.address}');
          }
        }
      }
    } catch (_) {}
    final csr = X509Utils.generateRsaCsrPem(
      {'CN': 'LocalVault'},
      priv,
      pub,
      san: sans,
    );
    final certPem = X509Utils.generateSelfSignedCertificate(
      priv,
      csr,
      825,
      sans: sans,
    );
    final keyPem = CryptoUtils.encodeRSAPrivateKeyToPem(priv);
    await File(keyPath).writeAsString(keyPem);
    await File(certPath).writeAsString(certPem);
    try {
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['600', keyPath]);
      }
    } catch (_) {}
    logInfo('TLS certificate ready.');
  }

  /// Lowercase hex SHA-256 over the DER bytes of a PEM certificate.
  static String fingerprintOfCertPem(String pem) {
    final lines = const LineSplitter().convert(pem.trim());
    final body = lines
        .where((l) => !l.startsWith('-----'))
        .join();
    final der = base64.decode(body);
    return sha256.convert(der).toString();
  }
}
