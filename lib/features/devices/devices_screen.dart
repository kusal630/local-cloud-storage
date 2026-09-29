import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/core/haptics/haptic_feedback.dart';
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
    } catch (_) {
      setState(() {
        // Never surface an exception string as UI copy — it leaks HTTP/TLS
        // internals the user can't act on. The retry is the affordance.
        _error = "Couldn't load your devices. Tap Retry to try again.";
        _loading = false;
      });
    }
  }

  Future<void> _revoke(Device device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // §10 copy deck: sentence case, and the consequence spelled out
        // rather than a bare "are you sure?".
        title: const Text('Revoke this device?'),
        content: Text(
            '${device.name} will no longer be able to connect to this host. '
            'You can pair it again at any time.'),
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
    // §9: medium is the destructive confirmation — same pattern the pool's
    // revoke sheet uses, so "I revoked something" feels identical everywhere.
    AppHaptics.medium();
    try {
      await ref.read(fileServiceProvider).revokeDevice(device.id);
      // Previously the list just reloaded in silence: a destructive action
      // that succeeds with no confirmation leaves the user guessing whether
      // the tap registered.
      AppHaptics.success();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${device.name} can no longer connect')),
        );
      }
      _load();
    } catch (_) {
      // A revoke can fail because the host is unreachable or the device
      // already disconnected — neither is an HTTP/TLS detail the user can
      // act on, so say what failed and offer the retry they can take.
      AppHaptics.error();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not revoke that device. Pull down to try again.'),
          ),
        );
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
                                        ? 'Last seen ${formatRelative(device.lastSeenAt!)}'
                                        : 'Just paired',
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                              trailing: device.isCurrent
                                  ? null
                                  : IconButton(
                                      icon: Icon(Icons.block,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error),
                                      tooltip: 'Revoke ${device.name}',
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