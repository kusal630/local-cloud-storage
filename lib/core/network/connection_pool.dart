import 'dart:async';
import 'dart:io';

/// HTTP connection pool for reusing connections.
///
/// Reduces connection overhead by keeping alive connections.
class ConnectionPool {
  ConnectionPool({
    this.maxConnections = 6,
    this.connectionTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
  });

  final int maxConnections;
  final Duration connectionTimeout;
  final Duration idleTimeout;

  final Map<String, List<HttpClient>> _pools = {};
  final Map<String, DateTime> _lastUsed = {};

  /// Get a connection for the given host.
  Future<HttpClient> getConnection(String host, {int port = 443}) async {
    final key = '$host:$port';
    final pool = _pools[key] ??= [];

    // Reuse existing connection
    if (pool.isNotEmpty) {
      _lastUsed[key] = DateTime.now();
      return pool.removeLast();
    }

    // Create new connection if under limit
    if (_countAll() < maxConnections) {
      final client = HttpClient()
        ..connectionTimeout = connectionTimeout
        ..idleTimeout = idleTimeout;
      _lastUsed[key] = DateTime.now();
      return client;
    }

    // Wait for a connection to become available
    await Future.delayed(const Duration(milliseconds: 100));
    return getConnection(host, port: port);
  }

  /// Return a connection to the pool.
  void returnConnection(String host, int port, HttpClient client) {
    final key = '$host:$port';
    final pool = _pools[key] ??= [];
    if (pool.length < maxConnections) {
      pool.add(client);
      _lastUsed[key] = DateTime.now();
    } else {
      client.close();
    }
  }

  int _countAll() {
    int count = 0;
    for (final pool in _pools.values) {
      count += pool.length;
    }
    return count;
  }

  /// Close all connections.
  void closeAll() {
    for (final pool in _pools.values) {
      for (final client in pool) {
        client.close();
      }
    }
    _pools.clear();
    _lastUsed.clear();
  }

  /// Close idle connections.
  void closeIdle() {
    final now = DateTime.now();
    for (final key in _pools.keys.toList()) {
      final pool = _pools[key]!;
      final lastUsed = _lastUsed[key];
      if (lastUsed != null && now.difference(lastUsed) > idleTimeout) {
        for (final client in pool) {
          client.close();
        }
        pool.clear();
        _pools.remove(key);
        _lastUsed.remove(key);
      }
    }
  }
}
