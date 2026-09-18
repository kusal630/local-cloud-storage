import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/data/models/storage_status.dart';
import 'package:localvault/widgets/common.dart';

class StorageScreen extends ConsumerStatefulWidget {
  const StorageScreen({super.key});
  @override
  ConsumerState<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends ConsumerState<StorageScreen> {
  StorageStatus? _status;
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
      final status = await svc.storageStatus();
      setState(() {
        _status = status;
        _loading = false;
      });
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
      appBar: AppBar(title: const Text('Storage')),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _status == null
                  ? const EmptyState(
                      icon: Icons.sd_storage,
                      title: 'No storage info',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          // Overview card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SectionHeader(title: 'DISK USAGE'),
                                  StorageMeter(
                                    fraction: _status!.usedFraction,
                                    usedLabel:
                                        'Used: ${formatBytes(_status!.used)}',
                                    freeLabel:
                                        'Free: ${formatBytes(_status!.free)}',
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  const SizedBox(height: 8),
                                  _buildRow('Total', formatBytes(_status!.total)),
                                  _buildRow('Free', formatBytes(_status!.free)),
                                  _buildRow('Used', formatBytes(_status!.used)),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Vault card
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SectionHeader(title: 'VAULT USAGE'),
                                  StorageMeter(
                                    fraction: _status!.vaultFraction,
                                    usedLabel:
                                        'Vault: ${formatBytes(_status!.vaultUsage)}',
                                    freeLabel:
                                        'Trash: ${formatBytes(_status!.trashUsage)}',
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                  const SizedBox(height: 8),
                                  _buildRow(
                                      'Vault', formatBytes(_status!.vaultUsage)),
                                  _buildRow('Trash',
                                      formatBytes(_status!.trashUsage)),
                                  _buildRow(
                                      'Total Vault',
                                      formatBytes(
                                          _status!.vaultUsage + _status!.trashUsage)),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
    );
  }

  Widget _buildRow(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            Text(value,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      );
}