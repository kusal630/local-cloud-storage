import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/core/utils/cipher.dart';
import 'package:localvault/server/pool/pool_node.dart';
import 'package:localvault/server/pool/pool_node_client.dart';
import 'package:localvault/server/pool/pool_node_server.dart';

/// CONSULT §5 requires pool traffic to ride a **pinned** channel — not
/// merely a valid one.
///
/// The pin used to live entirely inside `badCertificateCallback`, which Dart
/// only consults after chain validation has already failed. Any
/// publicly-trusted certificate for the right host therefore validated on its
/// own and the comparison never ran (defect D8). These tests are the
/// regression suite for the fix: the fingerprint must be the only thing that
/// can accept a certificate, and "could not verify" must be reported
/// differently from "proved wrong", because the fixes are different.
///
/// `test/fixtures/pool_node.{crt,key}` is a throwaway self-signed certificate
/// generated for this suite — a private key that is committed on purpose,
/// because it authenticates nothing outside `flutter test`.
void main() {
  // `TestWidgetsFlutterBinding` stubs every HttpClient to 400; this suite
  // needs a real TLS handshake.
  final previousOverrides = HttpOverrides.current;
  HttpOverrides.global = null;

  const certPath = 'test/fixtures/pool_node.crt';
  const keyPath = 'test/fixtures/pool_node.key';
  const token = 'tls-test-token';

  late Directory root;
  late PoolNodeStore store;
  late PoolNodeServer node;
  late PoolNodeClient client;
  late String pin;

  setUp(() async {
    root = Directory(
        '${Directory.systemTemp.path}/lv_tls_${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    store = PoolNodeStore(dir: root, quotaBytes: 8 << 20);
    await store.open();
    node = await PoolNodeServer.start(
      store: store,
      tokenHash: Cipher.sha256String(token),
      preferredPort: 0,
      certPath: certPath,
      keyPath: keyPath,
    );
    client = PoolNodeClient();
    pin = LocalVaultApi.fingerprintOfPem(File(certPath).readAsStringSync());
  });

  tearDown(() async {
    client.close();
    await node.stop();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
    HttpOverrides.global = previousOverrides;
  });

  NodeTarget targetFor({String? fingerprint}) => NodeTarget(
        baseUrl: 'https://127.0.0.1:${Uri.parse(node.baseUrl).port}',
        token: token,
        fingerprint: fingerprint,
      );

  test('a certificate matching the pin is accepted', () async {
    final call = await client.status(targetFor(fingerprint: pin));
    expect(call.ok, isTrue, reason: '${call.errorCode}: ${call.message}');
    expect(call.statusCode, 200);
  });

  test('the same certificate with a wrong pin is refused', () async {
    final call = await client.status(targetFor(fingerprint: '0' * 64));
    expect(call.ok, isFalse);
    expect(call.errorCode, 'PIN_MISMATCH');
    expect(call.message, contains('pinned fingerprint'),
        reason: 'the fix for a spoof is investigation, not re-registration');
  });

  test('no fingerprint means no connection, with the reason spelled out',
      () async {
    final call = await client.status(targetFor());
    expect(call.ok, isFalse);
    expect(call.errorCode, 'NO_FINGERPRINT');
    expect(call.message, contains('cannot be verified'));
    expect(call.message, contains('64-hex'),
        reason: 'name the fix, not just the failure');
  });

  test('a pin is case- and separator-insensitive, as stored', () async {
    final upper = pin.toUpperCase();
    final colonised = [
      for (var i = 0; i < upper.length; i += 2) upper.substring(i, i + 2),
    ].join(':');

    final call = await client.status(
      targetFor(fingerprint: colonised.toLowerCase()),
    );
    expect(call.ok, isTrue, reason: '${call.errorCode}: ${call.message}');
    expect(
      await client.status(targetFor(fingerprint: upper)).then((c) => c.ok),
      isTrue,
      reason: 'the coordinator stores the fingerprint verbatim from the '
          'device, which may print it in upper case with colons',
    );
  });

  test('a forged token is still refused on an accepted channel', () async {
    final call = await client.status(
      NodeTarget(
        baseUrl: 'https://127.0.0.1:${Uri.parse(node.baseUrl).port}',
        token: 'not-the-token',
        fingerprint: pin,
      ),
    );
    expect(call.statusCode, 401);
    expect(call.isUnauthorized, isTrue);
  });
}
