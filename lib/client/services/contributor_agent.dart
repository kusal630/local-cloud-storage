// The "this device contributes storage" agent for the v2.4.0 Pooled Data
// Cloud: it registers this device with the coordinator, publishes a
// quota-capped storage node on the LAN and reports usage on a heartbeat
// (RESEARCH/CONSULT.md §1 registry/heartbeat, §4 monotonic report sequence).
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../server/pool/pool_node.dart';
import '../../server/pool/pool_node_server.dart';
import '../api_client.dart';
import 'pool_service.dart';

/// What the UI should render for this device's contribution attempt:
/// JOINING → ONLINE → FAILED (back to [idle] after [ContributorAgent.stop]).
enum PoolAgentState {
  /// Not contributing (never started, or stopped).
  idle,

  /// Registration / node startup in flight.
  joining,

  /// Registered, node published, heartbeats landing.
  online,

  /// Registration or repeated heartbeats failed.
  failed,
}

/// Everything the agent persists between runs so an app restart *resumes*
/// instead of double-registering (a second `POST /pool/register` would create
/// a second contributor row and double-count its quota).
class PoolAgentRecord {
  const PoolAgentRecord({
    required this.contributorId,
    required this.token,
    required this.quotaBytes,
    this.reportSeq = 0,
    this.endpoint,
    this.deviceKind = 'phone',
    this.name,
  });

  final String contributorId;

  /// Capability token from `POST /pool/register` — keystore only (§1).
  final String token;

  final int quotaBytes;

  /// Last `report_seq` handed to the coordinator; monotonically increasing
  /// (§4) and written *before* each send so a crash can never resend a lower
  /// sequence.
  final int reportSeq;

  /// `http(s)://<lan-ip>:<port>` last advertised to the coordinator.
  final String? endpoint;

  final String deviceKind;

  final String? name;

  PoolAgentRecord copyWith({
    String? contributorId,
    String? token,
    int? quotaBytes,
    int? reportSeq,
    String? endpoint,
    String? deviceKind,
    String? name,
  }) {
    return PoolAgentRecord(
      contributorId: contributorId ?? this.contributorId,
      token: token ?? this.token,
      quotaBytes: quotaBytes ?? this.quotaBytes,
      reportSeq: reportSeq ?? this.reportSeq,
      endpoint: endpoint ?? this.endpoint,
      deviceKind: deviceKind ?? this.deviceKind,
      name: name ?? this.name,
    );
  }
}

/// Tiny persistence surface the [ContributorAgent] needs.
///
/// Declared as an interface (instead of mocking a plugin) so unit tests can
/// swap in an in-memory implementation.
abstract class PoolAgentStorage {
  /// Persisted membership, or null when this device never joined (or left).
  Future<PoolAgentRecord?> read();

  Future<void> write(PoolAgentRecord record);

  /// Forgets the membership — used after a voluntary leave.
  Future<void> clear();
}

/// Production storage: the capability token in the platform keystore, the
/// rest in shared preferences (same split as [SessionStore]).
class SecurePoolAgentStorage implements PoolAgentStorage {
  SecurePoolAgentStorage({
    FlutterSecureStorage? secureStorage,
    SharedPreferences? preferences,
  })  : _secure = secureStorage ?? const FlutterSecureStorage(),
        _prefs = preferences;

  static const String _kToken = 'pool_token';
  static const String _kContributorId = 'pool_contributor_id';
  static const String _kQuotaBytes = 'pool_quota_bytes';
  static const String _kReportSeq = 'pool_report_seq';
  static const String _kEndpoint = 'pool_endpoint';
  static const String _kDeviceKind = 'pool_device_kind';
  static const String _kName = 'pool_device_name';

  static const List<String> _prefKeys = [
    _kContributorId,
    _kQuotaBytes,
    _kReportSeq,
    _kEndpoint,
    _kDeviceKind,
    _kName,
  ];

  final FlutterSecureStorage _secure;
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _shared async =>
      _prefs ??= await SharedPreferences.getInstance();

  @override
  Future<PoolAgentRecord?> read() async {
    final token = await _secure.read(key: _kToken);
    if (token == null || token.isEmpty) return null;
    final prefs = await _shared;
    final contributorId = prefs.getString(_kContributorId);
    if (contributorId == null || contributorId.isEmpty) return null;
    return PoolAgentRecord(
      contributorId: contributorId,
      token: token,
      quotaBytes: prefs.getInt(_kQuotaBytes) ?? 0,
      reportSeq: prefs.getInt(_kReportSeq) ?? 0,
      endpoint: prefs.getString(_kEndpoint),
      deviceKind: prefs.getString(_kDeviceKind) ?? 'phone',
      name: prefs.getString(_kName),
    );
  }

  @override
  Future<void> write(PoolAgentRecord record) async {
    await _secure.write(key: _kToken, value: record.token);
    final prefs = await _shared;
    await prefs.setString(_kContributorId, record.contributorId);
    await prefs.setInt(_kQuotaBytes, record.quotaBytes);
    await prefs.setInt(_kReportSeq, record.reportSeq);
    await prefs.setString(_kDeviceKind, record.deviceKind);
    final endpoint = record.endpoint;
    if (endpoint == null) {
      await prefs.remove(_kEndpoint);
    } else {
      await prefs.setString(_kEndpoint, endpoint);
    }
    final name = record.name;
    if (name == null) {
      await prefs.remove(_kName);
    } else {
      await prefs.setString(_kName, name);
    }
  }

  @override
  Future<void> clear() async {
    await _secure.delete(key: _kToken);
    final prefs = await _shared;
    for (final key in _prefKeys) {
      await prefs.remove(key);
    }
  }
}

/// Donates this device's free disk to the pooled data cloud.
///
/// Lifecycle:
/// * [start] — opens the quota-capped [PoolNodeStore], registers with the
///   coordinator (`POST /pool/register`) to obtain the capability token,
///   starts the [PoolNodeServer] with `sha256(token)` and begins heartbeats.
/// * [heartbeatTick] — one monotonic `report_seq` usage report (called by the
///   internal 60 s timer; safe to call directly).
/// * [stop] — stops the node and optionally leaves the pool.
/// * [dispose] — cancels every timer and stops the node; nothing this object
///   created can outlive it.
///
/// Membership (contributor id, token, quota, report sequence) is persisted so
/// an app restart resumes the same contributor instead of creating a second
/// one (CONSULT §4: totals are derived per contributor row).
class ContributorAgent {
  ContributorAgent({
    required this.pool,
    required this.nodeDir,
    PoolAgentStorage? storage,
    this.deviceName,
    this.certPath,
    this.keyPath,
    this.preferredPort = 5321,
  }) : _storage = storage ?? SecurePoolAgentStorage();

  /// The coordinator client this agent talks to.
  final PoolService pool;

  /// Directory the quota-capped node stores its chunks in.
  final Directory nodeDir;

  /// Human name registered with the host; falls back to the platform host
  /// name when unset.
  final String? deviceName;

  /// Optional bring-your-own PEM pair: with both set the node serves HTTPS
  /// and its certificate fingerprint is registered with the coordinator
  /// (pinned-TLS lane, CONSULT §1/§5).
  final String? certPath;
  final String? keyPath;

  /// Port the storage node prefers (the coordinator's endpoint uses it).
  final int preferredPort;

  final PoolAgentStorage _storage;

  final StreamController<PoolAgentState> _states =
      StreamController<PoolAgentState>.broadcast();

  /// Fires on every state transition (JOINING → ONLINE → FAILED → ...).
  Stream<PoolAgentState> get stateChanges => _states.stream;

  /// Convenience listener for callers that do not want a subscription.
  void Function(PoolAgentState state)? onChanged;

  PoolAgentState _state = PoolAgentState.idle;

  /// Current lifecycle state.
  PoolAgentState get state => _state;

  PoolAgentRecord? _record;
  PoolNodeStore? _store;
  PoolNodeServer? _node;
  Timer? _timer;

  int _heartbeatSec = 60;
  int _consecutiveFailures = 0;
  bool _reRegistered = false;
  bool _ticking = false;
  bool _disposed = false;

  /// True while this device both holds a membership and publishes a node.
  bool get isContributing => _record != null && _node != null;

  /// Coordinator id of this device's contributor row, or null before join.
  String? get contributorId => _record?.contributorId;

  /// Quota cap this node enforces locally (and reports to the host).
  int get quotaBytes => _store?.quotaBytes ?? _record?.quotaBytes ?? 0;

  /// LAN base URL of the node once started, else the last advertised one.
  String? get endpoint => _node?.baseUrl ?? _record?.endpoint;

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Opens the storage node, joins (or resumes) the pool and starts the
  /// heartbeat timer.
  ///
  /// Resume path: a persisted contributor id + token skips registration and
  /// rebinds the previously advertised port, so an app restart never creates
  /// a second contributor row.
  Future<void> start({
    required int quotaBytes,
    String deviceKind = 'phone',
  }) async {
    if (_disposed) {
      throw StateError('ContributorAgent has been disposed.');
    }
    _timer?.cancel();
    await _stopNode();
    _setState(PoolAgentState.joining);

    try {
      final saved = await _storage.read();
      await _openStore(quotaBytes);
      final name = deviceName ?? Platform.localHostname;
      final scheme = _scheme;

      // The endpoint the coordinator will use to reach us. On resume we ask
      // for the port we advertised last time so that endpoint stays valid; a
      // fresh join probes for a free one first (the node then binds it).
      final port = _portOf(saved?.endpoint) ?? await _probePort(preferredPort);
      final endpoint = '$scheme://${await _lanAddress()}:$port';

      PoolAgentRecord record;
      final resumable = saved != null &&
          saved.contributorId.isNotEmpty &&
          saved.token.isNotEmpty &&
          saved.endpoint == endpoint;

      if (resumable) {
        record = saved.copyWith(quotaBytes: quotaBytes, deviceKind: deviceKind);
        if (saved.quotaBytes != quotaBytes) {
          try {
            await pool.setQuota(record.contributorId, quotaBytes);
          } on AppException catch (e) {
            // e.g. the new cap is below bytes already stored there — keep
            // the host's figure, the node still enforces its own cap.
            logWarn('Pool quota update rejected: ${e.message}');
          }
        }
      } else {
        final join = await pool.register(
          name: name,
          quotaBytes: quotaBytes,
          endpoint: endpoint,
          fingerprint: await nodeFingerprint(),
          deviceKind: deviceKind,
        );
        _heartbeatSec = join.heartbeatSec;
        record = PoolAgentRecord(
          contributorId: join.contributorId,
          token: join.token,
          quotaBytes: quotaBytes,
          // Keep the monotonic sequence across a re-registration; a fresh
          // contributor row simply accepts it as its first report.
          reportSeq: saved?.reportSeq ?? 0,
          endpoint: endpoint,
          deviceKind: deviceKind,
          name: name,
        );
      }

      _record = record;
      await _storage.write(record);
      await _startNode(token: record.token, preferredPort: port);

      // Belt and braces: if the node could not get the port we advertised,
      // the coordinator's endpoint is stale and placement would miss us.
      final actual = _node?.baseUrl;
      if (actual != null && actual != endpoint) {
        logWarn('Pool node bound $actual instead of $endpoint — re-registering.');
        final join = await pool.register(
          name: name,
          quotaBytes: quotaBytes,
          endpoint: actual,
          fingerprint: await nodeFingerprint(),
          deviceKind: deviceKind,
        );
        _heartbeatSec = join.heartbeatSec;
        record = record.copyWith(
          contributorId: join.contributorId,
          token: join.token,
          endpoint: actual,
        );
        _record = record;
        await _storage.write(record);
        await _startNode(
          token: join.token,
          preferredPort: _node?.port ?? port,
        );
      }

      _reRegistered = false;
      _consecutiveFailures = 0;
      _scheduleHeartbeats();
      _setState(PoolAgentState.online);
    } catch (e, st) {
      logError('Pool contributor failed to start', e, st);
      _setState(PoolAgentState.failed);
      rethrow;
    }
  }

  /// Stops the storage node and, when [leavePool] is set (the default),
  /// tells the coordinator this device is leaving and forgets the
  /// membership. With `leavePool: false` the membership stays persisted so a
  /// later [start] resumes it.
  Future<void> stop({bool leavePool = true}) async {
    _timer?.cancel();
    _timer = null;
    await _stopNode();

    if (leavePool) {
      final record = _record;
      if (record != null) {
        try {
          await pool.leave();
        } on AppException catch (e) {
          logWarn('Pool leave failed (membership cleared anyway): ${e.message}');
        }
      }
      _record = null;
      await _storage.clear();
    }
    _setState(PoolAgentState.idle);
  }

  /// One heartbeat: reports `used_bytes`/`free_bytes` under a strictly
  /// increasing `report_seq` (CONSULT §4).
  ///
  /// No-ops when there is no persisted membership. Throws typed
  /// [AppException]s (an [AuthException] means the capability token was
  /// revoked or expired — [start] re-registers instead of retrying it).
  Future<void> heartbeatTick() async {
    if (_disposed || _ticking) return;
    _ticking = true;
    try {
      final record = _record ?? await _storage.read();
      if (record == null ||
          record.contributorId.isEmpty ||
          record.token.isEmpty) {
        return;
      }
      _record = record;
      await _openStore(record.quotaBytes);
      final store = _store!;
      final usedBytes = store.usedBytes;
      final freeBytes = await store.diskFreeBytes();
      await _send(record, usedBytes: usedBytes, freeBytes: freeBytes);
    } on AppException catch (e) {
      // Three consecutive misses (CONSULT §1: SUSPECT at 180 s) — stop
      // pretending to be online so the screen can show FAILED.
      _consecutiveFailures += 1;
      logWarn(
          'Pool heartbeat failed (${_consecutiveFailures}x): ${e.message}');
      if (_consecutiveFailures >= 3 && !_disposed) {
        _setState(PoolAgentState.failed);
      }
      rethrow;
    } finally {
      _ticking = false;
    }
  }

  Future<PoolAgentRecord> _send(
    PoolAgentRecord record, {
    required int usedBytes,
    required int freeBytes,
  }) async {
    var current = record;
    for (var attempt = 0; attempt < 2; attempt++) {
      final seq = current.reportSeq + 1;
      final next = current.copyWith(reportSeq: seq);
      // Write-ahead: persist the sequence before the request so a crash can
      // never rewind it and make the host drop our reports as stale (§4).
      _record = next;
      await _storage.write(next);

      try {
        await pool.heartbeat(
          contributorId: next.contributorId,
          token: next.token,
          reportSeq: seq,
          usedBytes: usedBytes,
          freeBytes: freeBytes,
        );
        _consecutiveFailures = 0;
        if (_state != PoolAgentState.online && !_disposed) {
          _setState(PoolAgentState.online);
        }
        return next;
      } on AuthException {
        // 401: the host no longer honours our token — re-register once (§1)
        // rather than hammering a token it will never accept again.
        if (_reRegistered || _disposed) rethrow;
        _reRegistered = true;
        logWarn('Pool heartbeat rejected — re-registering this device.');
        current = await _reRegister(next);
        await _startNode(
          token: current.token,
          preferredPort: _node?.port ?? preferredPort,
        );
      }
    }
    return current;
  }

  /// Cancels every timer, stops the node and releases the state stream.
  ///
  /// The membership is left persisted (so the device resumes next run);
  /// call [stop] first to leave the pool deliberately.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _stopNode();
    _record = null;
    _setState(PoolAgentState.idle);
    await _states.close();
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<void> _openStore(int quotaBytes) async {
    final existing = _store;
    if (existing != null) {
      if (existing.quotaBytes != quotaBytes) existing.setQuota(quotaBytes);
      return;
    }
    final store = PoolNodeStore(dir: nodeDir, quotaBytes: quotaBytes);
    await store.open();
    _store = store;
  }

  Future<void> _startNode({required String token, required int preferredPort}) async {
    await _stopNode();
    _node = await PoolNodeServer.start(
      store: _store!,
      // The node only accepts the coordinator when it presents this token
      // (§1): sha256(token), exactly what the coordinator stored at register.
      tokenHash: Cipher.sha256String(token),
      preferredPort: preferredPort,
      certPath: certPath,
      keyPath: keyPath,
    );
    logInfo('Contributor node up at ${_node!.baseUrl}.');
  }

  Future<void> _stopNode() async {
    final node = _node;
    _node = null;
    if (node == null) return;
    try {
      await node.stop();
    } catch (e) {
      logWarn('Pool node stop failed: $e');
    }
  }

  void _scheduleHeartbeats() {
    _timer?.cancel();
    final seconds = _heartbeatSec > 0 ? _heartbeatSec : 60;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      unawaited(
        heartbeatTick().catchError(
          (Object e) => logWarn('Pool heartbeat failed: $e'),
        ),
      );
    });
  }

  /// Fresh registration after a rejected heartbeat: new token, same
  /// membership row semantics (the host issues a new contributor id).
  Future<PoolAgentRecord> _reRegister(PoolAgentRecord current) async {
    final endpoint = _node?.baseUrl ?? current.endpoint;
    final advertised = endpoint != null && endpoint.isNotEmpty
        ? endpoint
        : await _fallbackEndpoint(current);
    final join = await pool.register(
      name: current.name ?? deviceName ?? Platform.localHostname,
      quotaBytes: current.quotaBytes,
      endpoint: advertised,
      fingerprint: await nodeFingerprint(),
      deviceKind: current.deviceKind,
    );
    _heartbeatSec = join.heartbeatSec;
    final next = current.copyWith(
      contributorId: join.contributorId,
      token: join.token,
      endpoint: advertised,
    );
    _record = next;
    await _storage.write(next);
    _scheduleHeartbeats();
    return next;
  }

  void _setState(PoolAgentState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
    onChanged?.call(next);
  }

  // --- Address / endpoint helpers (mirror LocalVaultServer) ---------------

  String get _scheme => (certPath ?? '').isNotEmpty && (keyPath ?? '').isNotEmpty
      ? 'https'
      : 'http';

  /// First non-loopback IPv4 of this device, `127.0.0.1` when there is none
  /// — the address pattern `LocalVaultServer._localAddresses` uses.
  Future<String> _lanAddress() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      logWarn('Could not list network interfaces: $e');
    }
    return '127.0.0.1';
  }

  /// `http(s)://<lan-ip>:<port>` for a membership that has no endpoint yet
  /// (used when re-registering before the node is up).
  Future<String> _fallbackEndpoint(PoolAgentRecord record) async {
    final scheme = _scheme;
    final host = await _lanAddress();
    final port = _portOf(record.endpoint) ?? preferredPort;
    return '$scheme://$host:$port';
  }

  int? _portOf(String? endpoint) {
    if (endpoint == null || endpoint.isEmpty) return null;
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasPort) return null;
    return uri.port;
  }

  /// Probes for a free port starting at [preferred] (bind → close), the same
  /// strategy `LocalVaultServer._findFreePort` / `PoolNodeServer` use, so the
  /// endpoint registered with the host is the one the node actually binds.
  Future<int> _probePort(int preferred) async {
    try {
      final probe = await ServerSocket.bind(InternetAddress.anyIPv4, preferred);
      await probe.close();
      return preferred;
    } catch (_) {
      // Port busy — keep probing below.
    }
    for (var port = preferred + 1; port < preferred + 200; port++) {
      try {
        final probe = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await probe.close();
        return port;
      } catch (_) {
        // Port busy — keep probing.
      }
    }
    return preferred;
  }

  /// SHA-256 fingerprint of the node certificate, when this device serves
  /// TLS — registered so the coordinator pins our node (CONSULT §1/§5).
  Future<String?> nodeFingerprint() async {
    final cert = certPath;
    if (cert == null || cert.isEmpty) return null;
    try {
      final pem = await File(cert).readAsString();
      return LocalVaultApi.fingerprintOfPem(pem);
    } catch (e) {
      logWarn('Could not fingerprint the pool node certificate: $e');
      return null;
    }
  }
}
