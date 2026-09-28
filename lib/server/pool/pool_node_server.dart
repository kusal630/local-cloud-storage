import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;

import '../../core/logging/app_logger.dart';
import '../routes/pool_node_router.dart';
import 'pool_node.dart';

/// Shelf server that publishes a [PoolNodeStore] on the LAN so the
/// coordinator can replicate chunks to it (v2.4.0 Pooled Data Cloud,
/// `RESEARCH/CONSULT.md` §1/§6 — the node exposes raw opaque blobs only).
///
/// Plain HTTP by default; pass [certPath]/[keyPath] to `start` to serve
/// HTTPS from a bring-your-own PEM certificate (same `SecurityContext`
/// setup as `lib/server/server.dart`).
class PoolNodeServer {
  PoolNodeServer._(
    this._server, {
    required this._secure,
    required this._host,
  });

  final HttpServer _server;
  final bool _secure;
  final String _host;

  /// Bound port, or `null` before [start] / after [stop].
  int? get port => _server.port;

  /// True when serving TLS.
  bool get isSecure => _secure;

  /// `https` when [isSecure], else `http`.
  String get scheme => _secure ? 'https' : 'http';

  /// Reachable base URL of this node, e.g. `https://192.168.1.5:5321` —
  /// prefers a non-loopback IPv4 address of this device, falls back to
  /// `127.0.0.1`.
  String get baseUrl => '$scheme://$_host:${_server.port}';

  /// Serves [store] on [preferredPort]; when that port is busy the next
  /// free one is probed, so a busy LAN never blocks a node from joining.
  ///
  /// Binds `0.0.0.0`. [tokenHash] is the lowercase hex SHA-256 of the
  /// capability token the coordinator must send in `X-Pool-Token`.
  /// `store.open()` must have been awaited by the caller first.
  ///
  /// With both [certPath] and [keyPath] set, the server speaks HTTPS.
  static Future<PoolNodeServer> start({
    required PoolNodeStore store,
    required String tokenHash,
    int preferredPort = 5321,
    String? certPath,
    String? keyPath,
  }) async {
    final handler = buildPoolNodeHandler(store: store, tokenHash: tokenHash);
    final chosen = await _findFreePort(preferredPort);

    SecurityContext? tls;
    if (certPath != null && certPath.isNotEmpty && keyPath != null && keyPath.isNotEmpty) {
      tls = SecurityContext()
        ..useCertificateChain(certPath)
        ..usePrivateKey(keyPath);
    }

    final server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      chosen,
      securityContext: tls,
    );
    final host = await _preferredHost();
    final node = PoolNodeServer._(server, secure: tls != null, host: host);
    logInfo('Pool node listening on ${node.baseUrl}.');
    return node;
  }

  /// Stops the server; safe to call more than once.
  Future<void> stop() async {
    await _server.close(force: true);
    logInfo('Pool node stopped.');
  }

  /// Same probing strategy as `LocalVaultServer._findFreePort`: try
  /// [preferred], then scan the next 200 ports.
  static Future<int> _findFreePort(int preferred) async {
    try {
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, preferred);
      await probe.close();
      return preferred;
    } catch (_) {
      for (var port = preferred + 1; port < preferred + 200; port++) {
        try {
          final probe = await ServerSocket.bind(InternetAddress.anyIPv4, port);
          await probe.close();
          return port;
        } catch (_) {
          // Port busy — keep probing.
        }
      }
      throw const SocketException('No free port available.');
    }
  }

  /// First non-loopback IPv4 address of this device, `127.0.0.1` when the
  /// host has none (or when the interfaces cannot be listed).
  static Future<String> _preferredHost() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {
      // Fall through to loopback.
    }
    return '127.0.0.1';
  }
}
