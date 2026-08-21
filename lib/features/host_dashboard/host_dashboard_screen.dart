import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/widgets/common.dart';
import 'package:qr_flutter/qr_flutter.dart';

class HostDashboardScreen extends ConsumerStatefulWidget {
  const HostDashboardScreen({super.key});
  @override
  ConsumerState<HostDashboardScreen> createState() =>
      _HostDashboardScreenState();
}

class _HostDashboardScreenState extends ConsumerState<HostDashboardScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(hostStateProvider);
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Host Dashboard')),
        body: const ErrorState(message: 'No host is running.'),
      );
    }
    final server = data.server;
    final vault = data.vault;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Host Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: 'Stop Server',
            onPressed: () async {
              await server.stop();
              if (context.mounted) {
                ref.read(hostStateProvider.notifier).state = null;
                ref.read(appModeProvider.notifier).state = AppMode.welcome;
                context.go('/');
              }
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.circle,
                          size: 12,
                          color: server.isRunning ? Colors.green : Colors.red),
                      const SizedBox(width: 8),
                      Text(
                        server.isRunning ? 'Running' : 'Stopped',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (server.isRunning) ...[
                    Text('Server URL',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    _ServerUrls(server: server),
                    const SizedBox(height: 12),
                    Text('Pairing Code',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    _PairingSection(vault: vault, server: server),
                    const SizedBox(height: 16),
                    Text('Connected Devices',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    _DevicesList(vault: vault),
                    const SizedBox(height: 16),
                    Text('Storage',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 4),
                    _StorageInfo(vault: vault),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerUrls extends StatelessWidget {
  final dynamic server;
  const _ServerUrls({required this.server});
  @override
  Widget build(BuildContext context) {
    final urls = server.urls as List<String>;
    return Column(
      children: urls.map((url) => ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: SelectableText(url),
            trailing: IconButton(
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: url));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('URL copied')),
                );
              },
            ),
          )).toList(),
    );
  }
}

class _PairingSection extends StatefulWidget {
  final dynamic vault;
  final dynamic server;
  const _PairingSection({required this.vault, required this.server});
  @override
  State<_PairingSection> createState() => _PairingSectionState();
}

class _PairingSectionState extends State<_PairingSection> {
  String? _code;

  @override
  Widget build(BuildContext context) {
    final vault = widget.vault;
    final server = widget.server;
    final devices = vault.devices.listAll();
    if (devices.isEmpty) return const Text('No host device found.');
    _code ??= server.ensurePairingCode(devices.first.id);

    return Column(
      children: [
        QrImageView(
          data: 'localvault://${server.lanUrl ?? 'localhost:${server.port}'}',
          version: QrVersions.auto,
          size: 160,
        ),
        const SizedBox(height: 12),
        SelectableText(
          _code!,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        Text('Expires in 5 minutes',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => setState(() {
            _code = server.ensurePairingCode(devices.first.id);
          }),
          child: const Text('Regenerate'),
        ),
      ],
    );
  }
}

class _DevicesList extends ConsumerStatefulWidget {
  final dynamic vault;
  const _DevicesList({required this.vault});
  @override
  ConsumerState<_DevicesList> createState() => _DevicesListState();
}

class _DevicesListState extends ConsumerState<_DevicesList> {
  @override
  Widget build(BuildContext context) {
    final devices = widget.vault.devices.listAll();
    if (devices.isEmpty) return const Text('No devices connected yet.');
    return Column(
      children: devices
          .map((d) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    Icon(d.isCurrent ? Icons.computer : Icons.phone_android),
                title: Text(d.name),
                subtitle: Text(d.lastSeenAt != null
                    ? 'Last seen ${d.lastSeenAt}'
                    : 'Just paired'),
                trailing: d.isCurrent
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.block, size: 20),
                        tooltip: 'Revoke',
                        onPressed: () {
                          widget.vault.devices.revoke(d.id);
                          setState(() {});
                        },
                      ),
              ))
          .toList(),
    );
  }
}

class _StorageInfo extends ConsumerStatefulWidget {
  final dynamic vault;
  const _StorageInfo({required this.vault});
  @override
  ConsumerState<_StorageInfo> createState() => _StorageInfoState();
}

class _StorageInfoState extends ConsumerState<_StorageInfo> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: widget.vault.storageStatus(),
      builder: (context, AsyncSnapshot snapshot) {
        if (snapshot.hasError) {
          return Text('Error: ${snapshot.error}');
        }
        if (!snapshot.hasData) return const LoadingIndicator();
        final status = snapshot.data;
        return Column(
          children: [
            _row('Total', formatBytes(status.total)),
            _row('Free', formatBytes(status.free)),
            _row('Vault', formatBytes(status.vaultUsage)),
            _row('Trash', formatBytes(status.trashUsage)),
          ],
        );
      },
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text(value)],
        ),
      );
}