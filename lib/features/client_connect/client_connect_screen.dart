import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../client/services/auth_service.dart';
import '../../core/discovery/beacon.dart';
import '../../widgets/common.dart';

class ClientConnectScreen extends ConsumerStatefulWidget {
  const ClientConnectScreen({super.key});
  @override
  ConsumerState<ClientConnectScreen> createState() =>
      _ClientConnectScreenState();
}

class _ClientConnectScreenState extends ConsumerState<ClientConnectScreen> {
  final _urlController = TextEditingController();
  final _codeController = TextEditingController();
  final _nameController = TextEditingController(text: 'Client Device');
  final _userController = TextEditingController();
  final _passController = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _scanning = false;
  bool _trustHttps = false;
  bool _usePassword = false;
  bool _obscurePass = true;
  DiscoveryListener? _discovery;
  List<DiscoveredNode> _nearby = [];
  Set<String> _knownNodes = {};

  @override
  void dispose() {
    _urlController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    _userController.dispose();
    _passController.dispose();
    _discovery?.stop();
    super.dispose();
  }

  Future<void> _savePinFor(String url, String fingerprint) async {
    try {
      final host = Uri.parse(url).host;
      await ref.read(sessionStoreProvider).saveCertPin(host, fingerprint);
      await ref.read(sessionStoreProvider).saveCertPin(
          AuthService.hostKeyOf(url), fingerprint);
      ref.read(apiClientProvider).setPinnedFingerprint(fingerprint);
      setState(() => _trustHttps = false);
    } catch (_) {}
  }

  /// Verify-on-first-use: for manual https URLs without a saved pin, fetch
  /// the fingerprint and ask the user to confirm (compare with the host
  /// dashboard value). Returns false when the user declines.
  Future<bool> _ensurePin(String url) async {
    if (!url.startsWith('https://')) return true;
    final store = ref.read(sessionStoreProvider);
    String? saved;
    try {
      final host = Uri.parse(url).host;
      saved = await store.getCertPin(host) ??
          await store.getCertPin(AuthService.hostKeyOf(url));
    } catch (_) {}
    if (saved != null && saved.isNotEmpty) {
      ref.read(apiClientProvider).setPinnedFingerprint(saved);
      return true;
    }
    if (!mounted) return false;
    final messenger = ScaffoldMessenger.of(context);
    String? fetched;
    try {
      messenger.showSnackBar(
        const SnackBar(
            content: Text('Fetching host certificate…'), duration: Duration(seconds: 2)),
      );
      fetched = await AuthService.fetchFingerprint(url);
    } catch (e) {
      if (!mounted) return false;
      setState(() => _error = 'Could not fetch certificate: $e');
      return false;
    }
    if (!mounted) return false;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Trust this host?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'Compare with Host Dashboard → Pairing → TLS fingerprint:'),
            const SizedBox(height: 8),
            SelectableText(fetched!,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Trust & connect')),
        ],
      ),
    );
    if (approved != true) return false;
    await _savePinFor(url, fetched);
    return true;
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim().replaceFirst(RegExp(r'/$'), '');
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    final username = _userController.text.trim();
    final password = _passController.text;
    if (url.isEmpty) {
      setState(() => _error = 'Server URL is required.');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(() => _error = 'URL must start with http:// or https://.');
      return;
    }
    if (_usePassword) {
      if (username.isEmpty || password.isEmpty) {
        setState(
            () => _error = 'Username and password are required.');
        return;
      }
    } else {
      if (code.isEmpty) {
        setState(() => _error = 'Pairing code is required.');
        return;
      }
      if (code.length != 6) {
        setState(() => _error = 'Pairing code is 6 digits.');
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!await _ensurePin(url)) {
      if (!mounted) return;
      setState(() => _loading = false);
      return;
    }
    try {
      final authService = ref.read(authServiceProvider);
      ref.read(apiClientProvider).setTrustSelfSigned(_trustHttps);
      if (_usePassword) {
        await authService.login(
          serverUrl: url,
          username: username,
          password: password,
          deviceName: name.isEmpty ? 'Client Device' : name,
        );
      } else {
        await authService.pair(
          serverUrl: url,
          pairingCode: code,
          deviceName: name.isEmpty ? 'Client Device' : name,
        );
      }
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_server_url', url);
        await prefs.setBool('trust_https', _trustHttps);
      } catch (_) {}
      if (mounted) context.go('/client/files');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      final last = prefs.getString('last_server_url');
      if (last != null) _urlController.text = last;
      setState(() => _trustHttps = prefs.getBool('trust_https') ?? false);
    }).catchError((_) {});
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    final listener = DiscoveryListener();
    try {
      await listener.start();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _discovery = listener);
    listener.nodes.listen((nodes) async {
      if (!mounted) return;
      // Mark beacons whose certificate we already pinned as known.
      final known = <String>{};
      try {
        final store = ref.read(sessionStoreProvider);
        for (final n in nodes) {
          if (n.fingerprint.isEmpty) continue;
          final pin = await store.getCertPin(n.host) ??
              await store.getCertPin('${n.host}:${n.port}');
          if (pin != null && pin.isNotEmpty && pin == n.fingerprint) {
            known.add('${n.host}:${n.port}');
          }
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _nearby = nodes;
        _knownNodes = known;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Host')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SectionHeader(title: 'STEP 1 — SCAN'),
              // QR scan button
          OutlinedButton.icon(
            onPressed: () => setState(() => _scanning = !_scanning),
            icon: Icon(_scanning ? Icons.close : Icons.qr_code_scanner),
            label: Text(_scanning ? 'Stop Scanner' : 'Scan QR Code'),
          ),
          if (_scanning) ...[
            const SizedBox(height: 16),
            SizedBox(
              height: 250,
              child: MobileScanner(
                onDetect: (capture) {
                  final code = capture.barcodes.firstOrNull?.rawValue;
                  if (code == null) return;
                  // Expected: localvault://host:port[?fp=<sha256>]
                  var cleaned = code.replaceFirst('localvault://', '').trim();
                  String? fp;
                  final qIndex = cleaned.indexOf('?');
                  if (qIndex >= 0) {
                    final query = cleaned.substring(qIndex + 1);
                    cleaned = cleaned.substring(0, qIndex);
                    for (final part in query.split('&')) {
                      final kv = part.split('=');
                      if (kv.length == 2 && kv[0] == 'fp') fp = kv[1];
                    }
                  }
                  if (!cleaned.startsWith('http')) {
                    cleaned = 'http://$cleaned';
                  }
                  cleaned = cleaned.replaceFirst('https://', 'http://');
                  // Fingerprint present → modern HTTPS host: upgrade + pin.
                  // Absent → legacy plain-HTTP host: keep as scanned.
                  if (fp != null && fp.isNotEmpty) {
                    final httpsUrl =
                        cleaned.replaceFirst('http://', 'https://');
                    _urlController.text = httpsUrl;
                    _savePinFor(httpsUrl, fp);
                    setState(() => _scanning = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'QR scanned — certificate pinned. Enter code to connect.')),
                    );
                  } else {
                    _urlController.text = cleaned;
                    setState(() => _scanning = false);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content:
                              Text('QR scanned — enter code to connect')),
                    );
                  }
                },
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Nearby nodes via LAN discovery
          const SectionHeader(title: 'NEARBY NODES'),
          const SizedBox(height: 8),
          if (_nearby.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.radar_rounded,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                          'Listening for storage nodes…\nStart a node on the same Wi-Fi and it appears here.'),
                    ),
                  ],
                ),
              ),
            )
          else
            Card(
              child: Column(
                children: [
                  for (final node in _nearby)
                    ListTile(
                      leading: VaultFileIcon(
                          name: 'node', isFolder: false, size: 36),
                      title: Row(
                        children: [
                          Expanded(child: Text(node.deviceName)),
                          if (_knownNodes
                              .contains('${node.host}:${node.port}'))
                            const StatusPill(
                                label: 'KNOWN',
                                color: Color(0xFF43A047)),
                        ],
                      ),
                      subtitle: Text(
                          '${node.url}${node.secure ? ' • HTTPS' : ''}'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () {
                        _urlController.text = node.url;
                        if (node.secure && !_trustHttps) {
                          setState(() => _trustHttps = true);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'HTTPS node — self-signed trust enabled.')),
                          );
                        }
                      },
                    ),
                ],
              ),
            ),
          const SizedBox(height: 24),

          // Manual entry
          SectionHeader(
            title: _usePassword ? 'STEP 2 — LOGIN' : 'STEP 2 — ENTER CODE',
            action: TextButton(
              onPressed: () => setState(() => _usePassword = !_usePassword),
              child: Text(_usePassword ? 'Use pairing code' : 'Use password'),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'http://192.168.1.100:8484',
              prefixIcon: Icon(Icons.link),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          if (_usePassword) ...[
            TextField(
              controller: _userController,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'Cloud owner username',
                prefixIcon: Icon(Icons.person_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passController,
              obscureText: _obscurePass,
              decoration: InputDecoration(
                labelText: 'Password',
                prefixIcon: const Icon(Icons.lock_rounded),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePass
                      ? Icons.visibility_rounded
                      : Icons.visibility_off_rounded),
                  onPressed: () =>
                      setState(() => _obscurePass = !_obscurePass),
                ),
              ),
              onSubmitted: (_) => _connect(),
            ),
          ] else ...[
            TextField(
              controller: _codeController,
              decoration: const InputDecoration(
                labelText: 'Pairing Code',
                hintText: '6-digit code',
                prefixIcon: Icon(Icons.pin),
              ),
              keyboardType: TextInputType.number,
              maxLength: 6,
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Device Name',
              prefixIcon: Icon(Icons.devices),
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Trust self-signed HTTPS'),
            subtitle: const Text(
                'Needed only for hosts with a custom TLS certificate.'),
            value: _trustHttps,
            onChanged: (v) => setState(() => _trustHttps = v ?? false),
          ),
          const SizedBox(height: 16),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Card(
                color: colors.errorContainer.withValues(alpha: 0.6),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!,
                      style:
                          TextStyle(color: colors.onErrorContainer)),
                ),
              ),
            ),

          FilledButton.icon(
            onPressed: _loading ? null : _connect,
            icon: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.link_rounded),
            label: Text(_loading ? 'Connecting…' : 'Connect'),
          ),
          const SizedBox(height: 12),
          Text(
            'Reach the node from anywhere with a route to it: same Wi-Fi, phone hotspot, or a VPN such as Tailscale. Pairing codes expire in 5 minutes; password login uses your cloud username.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.outline),
          ),
            ],
          ),
        ),
      ),
    );
  }
}