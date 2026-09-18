import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/file_service.dart';
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
                          const SizedBox(height: 16),
                          const _BreakdownCard(),
                          const SizedBox(height: 16),
                          const _DuplicatesCard(),
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

class _BreakdownCard extends ConsumerWidget {
  const _BreakdownCard();

  static const _colors = {
    'images': Color(0xFF7C4DFF),
    'video': Color(0xFFE040FB),
    'audio': Color(0xFF00ACC1),
    'docs': Color(0xFF43A047),
    'archives': Color(0xFFFB8C00),
    'other': Color(0xFF90A4AE),
  };

  static const _labels = {
    'images': 'Images',
    'video': 'Video',
    'audio': 'Audio',
    'docs': 'Documents',
    'archives': 'Archives',
    'other': 'Other',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'BY TYPE'),
            FutureBuilder<Map<String, int>>(
              future:
                  ref.read(fileServiceProvider).storageBreakdown(),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('Breakdown unavailable.',
                      style: Theme.of(context).textTheme.bodySmall);
                }
                if (!snapshot.hasData) return const LoadingIndicator();
                final map = snapshot.data!;
                final total =
                    map.values.fold<int>(0, (a, b) => a + b);
                if (total <= 0) {
                  return const Text('Vault is empty.');
                }
                return Column(
                  children: [
                    for (final key in _labels.keys)
                      if ((map[key] ?? 0) > 0)
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(vertical: 5),
                          child: StorageMeter(
                            fraction: map[key]! / total,
                            usedLabel: _labels[key]!,
                            freeLabel: formatBytes(map[key]!),
                            color: _colors[key],
                          ),
                        ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Duplicate finder: groups sharing content, trash extras in one tap.
class _DuplicatesCard extends ConsumerStatefulWidget {
  const _DuplicatesCard();
  @override
  ConsumerState<_DuplicatesCard> createState() => _DuplicatesCardState();
}

class _DuplicatesCardState extends ConsumerState<_DuplicatesCard> {
  List<DuplicateGroup>? _groups;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final groups =
          await ref.read(fileServiceProvider).listDuplicates();
      if (!mounted) return;
      setState(() => _groups = groups);
    } catch (_) {}
  }

  Future<void> _trashExtras(DuplicateGroup group) async {
    // Keep the oldest copy, trash the rest.
    final extras = group.files.skip(1).toList();
    if (extras.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Trash ${extras.length} duplicate(s)?'),
        content: Text(
            'Keeps the oldest copy of "${extras.first.name}" and moves the rest to trash.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Trash')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _working = true);
    try {
      final svc = ref.read(fileServiceProvider);
      for (final f in extras) {
        await svc.deleteFile(f.id);
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Cleanup failed: $e')));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'DUPLICATES'),
            if (_groups == null)
              const LoadingIndicator()
            else if (_groups!.isEmpty)
              Text('No duplicate files — every byte is unique.',
                  style: Theme.of(context).textTheme.bodySmall)
            else
              for (final g in _groups!)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${g.files.length}× ${g.files.first.name} • wastes ${formatBytes(g.wastedBytes)}',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          TextButton(
                            onPressed: _working
                                ? null
                                : () => _trashExtras(g),
                            child: const Text('Clean'),
                          ),
                        ],
                      ),
                      for (final f in g.files)
                        Text('• ${f.name}',
                            style:
                                Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}