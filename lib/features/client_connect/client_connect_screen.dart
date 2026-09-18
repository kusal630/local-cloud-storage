import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
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
  bool _loading = false;
  String? _error;
  bool _scanning = false;

  @override
  void dispose() {
    _urlController.dispose();
    _codeController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final url = _urlController.text.trim().replaceFirst(RegExp(r'/$'), '');
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    if (url.isEmpty || code.isEmpty) {
      setState(() => _error = 'Server URL and pairing code are required.');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(() => _error = 'URL must start with http:// (LAN address).');
      return;
    }
    if (code.length != 6) {
      setState(() => _error = 'Pairing code is 6 digits.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final authService = ref.read(authServiceProvider);
      await authService.pair(
        serverUrl: url,
        pairingCode: code,
        deviceName: name.isEmpty ? 'Client Device' : name,
      );
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('last_server_url', url);
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
      final last = prefs.getString('last_server_url');
      if (last != null && mounted) _urlController.text = last;
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
                  // Expected: localvault://192.168.x.x:8484 (host path without scheme)
                  var cleaned = code.replaceFirst('localvault://', '').trim();
                  if (!cleaned.startsWith('http')) {
                    cleaned = 'http://$cleaned';
                  }
                  cleaned = cleaned.replaceFirst('https://', 'http://');
                  _urlController.text = cleaned;
                  setState(() => _scanning = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('QR scanned — enter code to connect')),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Manual entry
          const SectionHeader(title: 'STEP 2 — ENTER CODE'),
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
          const SizedBox(height: 12),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Device Name',
              prefixIcon: Icon(Icons.devices),
            ),
          ),
          const SizedBox(height: 24),

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
            'Both devices must be on the same Wi-Fi. Code expires in 5 minutes. Traffic is LAN-only HTTP.',
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