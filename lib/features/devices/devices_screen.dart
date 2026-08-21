import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/data/models/device.dart';
import 'package:localvault/widgets/common.dart';

class DevicesScreen extends ConsumerStatefulWidget {
  const DevicesScreen({super.key});
  @override
  ConsumerState<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends ConsumerState<DevicesScreen> {
  List<Device> _devices = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(fileServiceProvider);
      final devices = await svc.listDevices();
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _revoke(Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Device?'),
        content: Text(
            '"${device.name}" will no longer be able to connect to this host.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(fileServiceProvider).revokeDevice(device.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Revoke failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      floatingActionButton: FloatingActionButton(
        onPressed: _load,
        tooltip: 'Refresh',
        child: const Icon(Icons.refresh),
      ),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _devices.isEmpty
                  ? const EmptyState(
                      icon: Icons.devices_other,
                      title: 'No devices',
                      subtitle: 'Paired devices will appear here.',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        itemCount: _devices.length,
                        itemBuilder: (context, i) {
                          final device = _devices[i];
                          return Card(
                            margin: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 4),
                            child: ListTile(
                              leading: Icon(
                                device.isCurrent
                                    ? Icons.computer
                                    : Icons.phone_android,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              title: Text(device.name),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('ID: ${device.id.substring(0, 8)}...'),
                                  Text(
                                    device.lastSeenAt != null
                                        ? 'Last seen: ${device.lastSeenAt!.toLocal().toString().substring(0, 16)}'
                                        : 'Just paired',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              trailing: device.isCurrent
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.block,
                                          color: Colors.red),
                                      tooltip: 'Revoke',
                                      onPressed: () => _revoke(device),
                                    ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}