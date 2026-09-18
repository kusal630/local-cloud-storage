import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/file_kinds.dart';

/// UDP port used for LAN presence announcements.
const int discoveryPort = 8485;

/// Host-side beacon: broadcasts `localvault-v1|name|host|port|scheme` every
/// 2 seconds so clients on the same LAN can discover this node without typing
/// an IP address. No new dependencies — plain dart:io datagrams.
class DiscoveryBeacon {
  DiscoveryBeacon({
    required this.deviceName,
    required this.port,
    this.secure = false,
    this.interval = const Duration(seconds: 2),
  });

  final String deviceName;
  final int port;
  final bool secure;
  final Duration interval;

  RawDatagramSocket? _socket;
  Timer? _timer;
  String? _host;

  Future<void> start() async {
    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _socket!.broadcastEnabled = true;
    _host = await _lanAddress();
    _timer = Timer.periodic(interval, (_) => _announce());
    _announce();
  }

  Future<String> _lanAddress() async {
    try {
      final ifaces = await NetworkInterface.list();
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  void _announce() {
    final socket = _socket;
    if (socket == null) return;
    final payload = FileKinds.beaconEncode(
      deviceName: deviceName,
      host: _host ?? '127.0.0.1',
      port: port,
      secure: secure,
    );
    try {
      socket.send(
        utf8.encode(payload),
        InternetAddress('255.255.255.255'),
        discoveryPort,
      );
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
  }
}

/// A storage node seen on the LAN.
class DiscoveredNode {
  const DiscoveredNode({
    required this.deviceName,
    required this.host,
    required this.port,
    required this.secure,
    required this.lastSeen,
  });

  final String deviceName;
  final String host;
  final int port;
  final bool secure;
  final DateTime lastSeen;

  String get url => '${secure ? 'https' : 'http'}://$host:$port';
}

/// Client-side listener collecting nearby nodes.
class DiscoveryListener {
  DiscoveryListener({this.staleAfter = const Duration(seconds: 8)});

  final Duration staleAfter;
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  final Map<String, DiscoveredNode> _nodes = {};
  final StreamController<List<DiscoveredNode>> _controller =
      StreamController.broadcast();

  Stream<List<DiscoveredNode>> get nodes => _controller.stream;
  List<DiscoveredNode> get current => _pruned();

  Future<void> start() async {
    if (_socket != null) return;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    _sub = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final decoded = FileKinds.beaconDecode(utf8.decode(dg.data, allowMalformed: true).trim());
      if (decoded == null) return;
      final key = '${decoded.host}:${decoded.port}';
      _nodes[key] = DiscoveredNode(
        deviceName: decoded.deviceName,
        host: decoded.host,
        port: decoded.port,
        secure: decoded.secure,
        lastSeen: DateTime.now(),
      );
      if (!_controller.isClosed) _controller.add(_pruned());
    });
  }

  List<DiscoveredNode> _pruned() {
    final cutoff = DateTime.now().subtract(staleAfter);
    _nodes.removeWhere((_, n) => n.lastSeen.isBefore(cutoff));
    final list = _nodes.values.toList()
      ..sort((a, b) => a.deviceName.compareTo(b.deviceName));
    return list;
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _nodes.clear();
    await _controller.close();
  }
}
