import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:uuid/uuid.dart';

import '../core/constants/app_constants.dart';
import '../core/discovery/beacon.dart';
import '../core/host/host_service_control.dart';
import '../core/logging/app_logger.dart';
import '../data/datasources/vault.dart';
import 'middleware/auth_middleware.dart';
import 'routes/api_router.dart';
import 'services/pairing_service.dart';
import 'services/token_service.dart';
import 'tls/cert_store.dart';

/// Runs the shelf HTTP server on a background isolate so heavy transfers
/// never block the UI isolate.
///
/// The isolate owns its own [Vault] database connection (SQLite WAL mode
/// serializes the rare concurrent writes; the busy timeout absorbs them).
/// Pairing codes and token issuance live in the isolate and are reached via
/// a tiny RPC. Everything the dashboard needs (devices, storage, settings,
/// audit) is served from a second connection owned by [vault] on the UI
/// isolate.
class HostRunner {
  HostRunner._({
    required this.vault,
    required this.port,
    required this.fingerprint,
    required this.secure,
    required this._isolate,
    required this._control,
  });

  /// UI-isolate vault handle (dashboard reads, settings, audit).
  final Vault vault;
  final int port;
  final String? fingerprint;
  final bool secure;

  final Isolate _isolate;
  final SendPort _control;
  DiscoveryBeacon? _beacon;
  bool _running = true;

  String get scheme => secure ? 'https' : 'http';
  bool get isRunning => _running;
  bool get isSecure => secure;

  int _rpcId = 0;
  final Map<int, Completer<Map<String, Object?>>> _pending = {};

  /// Starts a node for the vault at [storagePath] (must already exist).
  static Future<HostRunner> start({
    required String storagePath,
    int preferredPort = AppConstants.defaultPort,
  }) async {
    final vault = Vault.open(Directory(storagePath));
    // Older vaults predate the host device row — backfill it.
    try {
      vault.devices.ensureHostDevice(vault.settings.hostDeviceName);
    } catch (e) {
      logWarn('Host device backfill failed: $e');
    }
    final tls = await CertStore.ensure(vault);
    try {
      await vault.purgeExpiredTrash();
    } catch (e) {
      logWarn('Trash auto-purge failed: $e');
    }

    final readyPort = ReceivePort();
    HostRunner? runner;
    final completer = Completer<Map<String, Object?>>();
    readyPort.listen((message) {
      if (message is! Map) return;
      final map = Map<String, Object?>.from(message);
      if (map['type'] == 'resp') {
        runner?._route(map);
        return;
      }
      if (!completer.isCompleted) completer.complete(map);
    });
    final isolate = await Isolate.spawn(
      _entry,
      _IsolateArgs(
        replyTo: readyPort.sendPort,
        storagePath: storagePath,
        certPath: tls?.certPath,
        keyPath: tls?.keyPath,
        preferredPort: preferredPort,
      ),
      debugName: 'localvault-server',
    );
    final ready = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        isolate.kill(priority: Isolate.immediate);
        throw const SocketException('Server isolate did not start in time.');
      },
    );
    if (ready['type'] == 'error') {
      isolate.kill(priority: Isolate.immediate);
      vault.close();
      throw ServerStartExceptionFallback('${ready['message']}');
    }

    final node = HostRunner._(
      vault: vault,
      port: ready['port'] as int,
      fingerprint: tls?.fingerprint,
      secure: tls != null,
      isolate: isolate,
      control: ready['control'] as SendPort,
    );
    runner = node;

    try {
      node._beacon = DiscoveryBeacon(
        deviceName: vault.settings.hostDeviceName,
        port: node.port,
        secure: node.secure,
      );
      await node._beacon!.start();
    } catch (e) {
      logWarn('LAN discovery beacon failed: $e');
    }
    try {
      await HostServiceControl.start(
        label: vault.settings.hostDeviceName,
        port: node.port,
      );
    } catch (e) {
      logWarn('Host foreground service failed: $e');
    }
    logInfo('LocalVault node on ${node.scheme} port ${node.port}');
    return node;
  }

  Future<Map<String, Object?>> _rpc(
      String cmd, Map<String, Object?> fields) {
    final id = ++_rpcId;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    _control.send({'cmd': cmd, 'id': id, ...fields});
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _pending.remove(id);
        return const {};
      },
    );
  }

  /// Routes an isolate `resp` message to its pending RPC.
  void _route(Map<String, Object?> message) {
    final id = message['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    completer?.complete(message);
  }

  /// Returns the active pairing code for [deviceId], issuing one if needed.
  Future<String> ensurePairingCode(String deviceId) async {
    final current = await _rpc('current', {'deviceId': deviceId});
    final code = current['code'] as String?;
    if (code != null && code.isNotEmpty) return code;
    final issued = await _rpc('issue', {'deviceId': deviceId});
    return (issued['code'] as String?) ?? '';
  }

  /// Creates a long-lived API token (plaintext returned once).
  Future<({String deviceId, String access, String refresh})> createApiToken({
    required String name,
    int days = 365,
  }) async {
    final resp = await _rpc('token', {'name': name, 'days': days});
    return (
      deviceId: (resp['device'] as String?) ?? '',
      access: (resp['code'] as String?) ?? '',
      refresh: (resp['extra'] as String?) ?? '',
    );
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

  Future<String?> lanUrl() async {
    final addresses = await _localAddresses();
    if (addresses.isEmpty) return null;
    return '$scheme://${addresses.first}:$port';
  }

  Future<List<String>> urls() async {
    final result = <String>[];
    for (final addr in await _localAddresses()) {
      result.add('$scheme://$addr:$port');
    }
    result.add('$scheme://127.0.0.1:$port');
    return result;
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    try {
      await HostServiceControl.stop();
    } catch (_) {}
    try {
      _beacon?.stop();
    } catch (_) {}
    _beacon = null;
    try {
      _control.send({'cmd': 'stop'});
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      _isolate.kill(priority: Isolate.immediate);
    } catch (_) {}
    for (final c in _pending.values) {
      if (!c.isCompleted) c.complete(const {});
    }
    _pending.clear();
    try {
      vault.close();
    } catch (_) {}
    logInfo('LocalVault server stopped.');
  }
}

class _IsolateArgs {
  const _IsolateArgs({
    required this.replyTo,
    required this.storagePath,
    required this.preferredPort,
    this.certPath,
    this.keyPath,
  });

  final SendPort replyTo;
  final String storagePath;
  final int preferredPort;
  final String? certPath;
  final String? keyPath;
}

/// Server-isolate entry point. Never touches UI-isolate objects.
Future<void> _entry(_IsolateArgs args) async {
  final replies = ReceivePort();
  try {
    final vault = Vault.open(Directory(args.storagePath));
    final tokens = TokenService(vault);
    final auth = AuthMiddleware(vault);
    final pairing = PairingCodeStore();
    final Handler handler = buildApiHandler(
      vault: vault,
      tokenService: tokens,
      auth: auth,
      pairingStore: pairing,
    );

    SecurityContext? tls;
    if (args.certPath != null && args.keyPath != null) {
      tls = SecurityContext()
        ..useCertificateChain(args.certPath!)
        ..usePrivateKey(args.keyPath!);
    }
    final port = await _findFreePort(args.preferredPort);
    final server = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      port,
      securityContext: tls,
    );

    void respond(int? id, String? code,
        {String? device, String? extra}) {
      args.replyTo.send({
        'type': 'resp',
        'id': id,
        'code': code,
        if (device != null) 'device': device,
        if (extra != null) 'extra': extra,
      });
    }

    replies.listen((message) async {
      if (message is! Map) return;
      final cmd = message['cmd']?.toString();
      final id = message['id'] as int?;
      if (cmd == 'stop') {
        try {
          await server.close(force: true);
        } catch (_) {}
        try {
          vault.close();
        } catch (_) {}
        replies.close();
        Isolate.exit();
      } else if (cmd == 'issue' || cmd == 'current') {
        final deviceId = message['deviceId']?.toString() ?? '';
        String? code;
        try {
          code = cmd == 'issue'
              ? pairing.issue(deviceId: deviceId)
              : pairing.currentCodeFor(deviceId);
        } catch (_) {
          code = null;
        }
        respond(id, code);
      } else if (cmd == 'token') {
        final name = message['name']?.toString().trim().isEmpty == true
            ? 'API token'
            : message['name'].toString().trim();
        var days = 365;
        try {
          days = int.parse(message['days'].toString()).clamp(1, 3650);
        } catch (_) {}
        final lifetime = Duration(days: days);
        try {
          final created = tokens.createDevice(
            deviceId: const Uuid().v4(),
            deviceName: 'token: $name',
            accessLifetime: lifetime,
            refreshLifetime: lifetime,
          );
          vault.mutated(
            action: 'device.token.create',
            targetId: created.deviceId,
            targetName: name,
            detail: '${days}d',
          );
          respond(id, created.accessToken,
              device: created.deviceId, extra: created.refreshToken);
        } catch (_) {
          respond(id, null);
        }
      }
    });

    args.replyTo.send({
      'type': 'ready',
      'port': server.port,
      'control': replies.sendPort,
    });
  } catch (e) {
    args.replyTo.send({'type': 'error', 'message': '$e'});
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

class ServerStartExceptionFallback implements Exception {
  const ServerStartExceptionFallback(this.message);
  final String message;
  @override
  String toString() => message;
}
