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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusPill(
                            label: server.isRunning ? 'RUNNING' : 'STOPPED',
                            color: server.isRunning
                                ? const Color(0xFF43A047)
                                : Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          const StatusPill(
                            label: 'LAN-ONLY :8484',
                            color: Color(0xFF0E7C7B),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const SectionHeader(title: 'CONNECT'),
                      if (server.isRunning) ...[
                        const Text('Server URL'),
                        const SizedBox(height: 4),
                        _ServerUrls(server: server),
                        const SizedBox(height: 12),
                        const Text('Pairing Code'),
                        const SizedBox(height: 4),
                        _PairingSection(vault: vault, server: server),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'DEVICES'),
                      _DevicesList(vault: vault),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'STORAGE'),
                      _StorageInfo(vault: vault),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
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
          data: 'localvault://${(server.lanUrl ?? 'localhost:${server.port}').replaceFirst(RegExp(r'^https?://'), '')}',
          version: QrVersions.auto,
          size: 180,
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
    if (devices.isEmpty) {
      return const EmptyState(
        icon: Icons.devices_other_rounded,
        title: 'No devices yet',
        subtitle: 'Pair a phone or desktop with the QR code above.',
      );
    }
    return Column(
      children: devices
          .map((d) => Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: VaultFileIcon(
                      name: d.isCurrent ? 'host' : 'phone',
                      isFolder: false,
                      size: 36),
                  title: Text(d.name),
                  subtitle: Text(d.lastSeenAt != null
                      ? 'Last seen ${formatDateTime(d.lastSeenAt)}'
                      : 'Just paired'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (d.isCurrent)
                        const StatusPill(
                            label: 'HOST', color: Color(0xFF0E7C7B))
                      else
                        IconButton(
                          icon: const Icon(Icons.block_rounded, size: 20),
                          tooltip: 'Revoke',
                          onPressed: () {
                            widget.vault.devices.revoke(d.id);
                            setState(() {});
                          },
                        ),
                    ],
                  ),
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
        final total = (status.total as int);
        final free = (status.free as int);
        final used = total - free;
        final vaultUsage = (status.vaultUsage as int);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StorageMeter(
              fraction: total > 0 ? used / total : 0,
              usedLabel: 'Used ${formatBytes(used)}',
              freeLabel: 'Free ${formatBytes(free)}',
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            StorageMeter(
              fraction: total > 0 ? vaultUsage / total : 0,
              usedLabel: 'Vault ${formatBytes(vaultUsage)}',
              freeLabel: 'Trash ${formatBytes(status.trashUsage as int)}',
            ),
            const SizedBox(height: 8),
            _row('Total', formatBytes(total)),
            _row('Free', formatBytes(free)),
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