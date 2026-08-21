import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/providers.dart';

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
    final url = _urlController.text.trim();
    final code = _codeController.text.trim();
    final name = _nameController.text.trim();
    if (url.isEmpty || code.isEmpty) {
      setState(() => _error = 'Server URL and pairing code are required.');
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
        deviceName: name,
      );
      if (mounted) context.go('/client/files');
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to Host')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
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
                  final code = capture.barcodes.first.rawValue;
                  if (code == null) return;
                  // Expected: localvault://http://192.168.x.x:port
                  final cleaned = code
                      .replaceFirst('localvault://', '')
                      .replaceFirst('https://', 'http://');
                  _urlController.text = cleaned;
                  setState(() => _scanning = false);
                },
              ),
            ),
          ],
          const SizedBox(height: 24),

          // Manual entry
          Text('Manual Entry',
              style: Theme.of(context).textTheme.titleMedium),
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
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),

          FilledButton(
            onPressed: _loading ? null : _connect,
            child: _loading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Connect'),
          ),
        ],
      ),
    );
  }
}