import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../core/constants/app_constants.dart';
import '../core/logging/app_logger.dart';
import '../data/datasources/vault.dart';
import 'middleware/auth_middleware.dart';
import 'routes/api_router.dart';
import 'services/pairing_service.dart';
import 'services/token_service.dart';

/// Lifecycle state of the host server.
enum HostServerStatus {
  stopped,
  starting,
  running,
  error,
}

/// Wraps the shelf HTTP server that powers Host Mode.
///
/// Binds to the local network only (0.0.0.0). All vault operations run on the
/// same isolate that created this object, so the UI isolate is never blocked.
class LocalVaultServer {
  LocalVaultServer({required this.vault});

  final Vault vault;

  HttpServer? _server;
  late final TokenService _tokens;
  late final AuthMiddleware _auth;
  final PairingCodeStore pairingStore = PairingCodeStore();
  Handler? _handler;

  HostServerStatus _status = HostServerStatus.stopped;
  HostServerStatus get status => _status;

  int? _port;
  int? get port => _port;

  bool get isRunning => _status == HostServerStatus.running;

  /// Starts the server on [preferredPort]; when busy, the next free port is
  /// chosen automatically and exposed through [port].
  Future<int> start({int preferredPort = AppConstants.defaultPort}) async {
    if (isRunning) return _port!;
    _status = HostServerStatus.starting;
    try {
      _tokens = TokenService(vault);
      _auth = AuthMiddleware(vault);
      _handler = buildApiHandler(
        vault: vault,
        tokenService: _tokens,
        auth: _auth,
        pairingStore: pairingStore,
      );

      final chosen = await _findFreePort(preferredPort);
      _server = await shelf_io.serve(_handler!, InternetAddress.anyIPv4, chosen);
      _port = _server!.port;
      _status = HostServerStatus.running;
      final urls = await _localAddresses();
      logInfo('LocalVault server listening on ${urls.map((u) => 'http://$u:$_port').join(', ')}');
      return _port!;
    } catch (e, st) {
      _status = HostServerStatus.error;
      logError('Failed to start server', e, st);
      rethrow;
    }
  }

  Future<int> _findFreePort(int preferred) async {
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
        } catch (_) {}
      }
      throw const SocketException('No free port available.');
    }
  }

  Future<void> stop() async {
    if (_server != null) {
      await _server!.close(force: true);
      _server = null;
    }
    _port = null;
    _status = HostServerStatus.stopped;
    logInfo('LocalVault server stopped.');
  }

  Future<List<String>> _localAddresses() async {
    try {
      final interfaces = await NetworkInterface.list();
      final addresses = <String>[];
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            addresses.add(addr.address);
          }
        }
      }
      return addresses;
    } catch (_) {
      return const ['127.0.0.1'];
    }
  }

  /// The server URL a client on the same LAN should use.
  Future<String?> lanUrl() async {
    final port = _port;
    if (port == null) return null;
    final addresses = await _localAddresses();
    if (addresses.isEmpty) return null;
    return 'http://${addresses.first}:$port';
  }

  /// All reachable URLs (LAN IP + loopback).
  Future<List<String>> urls() async {
    final port = _port;
    if (port == null) return const [];
    final result = <String>[];
    for (final addr in await _localAddresses()) {
      result.add('http://$addr:$port');
    }
    result.add('http://127.0.0.1:$port');
    return result;
  }

  /// Returns the currently active pairing code for the host dashboard device,
  /// issuing a fresh one when none is active.
  String ensurePairingCode(String deviceId) {
    final existing = pairingStore.currentCodeFor(deviceId);
    if (existing != null) return existing;
    return pairingStore.issue(deviceId: deviceId);
  }
}