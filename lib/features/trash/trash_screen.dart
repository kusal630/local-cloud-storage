import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/widgets/common.dart';

class TrashScreen extends ConsumerStatefulWidget {
  const TrashScreen({super.key});
  @override
  ConsumerState<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends ConsumerState<TrashScreen> {
  List<VaultFile> _items = [];
  bool _loading = false;
  String? _error;
  int? _retentionDays;

  @override
  void initState() {
    super.initState();
    _load();
    _loadRetention();
  }

  /// Shows the safety window ("recoverable for N days") — reversibility
  /// messaging keeps deletes feeling safe.
  Future<void> _loadRetention() async {
    try {
      final settings = await ref.read(fileServiceProvider).getSettings();
      if (!mounted) return;
      setState(() => _retentionDays = settings.trashRetentionDays);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(fileServiceProvider);
      final items = await svc.listTrash();
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _restore(VaultFile file) async {
    try {
      await ref.read(fileServiceProvider).restoreFile(file.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
      }
    }
  }

  Future<void> _permanentDelete(VaultFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permanent Delete?'),
        content: Text(
            '"${file.name}" will be permanently deleted. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(fileServiceProvider).permanentDelete(file.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty Trash?'),
        content:
            const Text('All items will be permanently deleted. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Empty')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(fileServiceProvider).emptyTrash();
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Empty trash failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          if (_items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Empty Trash',
              onPressed: _emptyTrash,
            ),
        ],
      ),
      body: _loading
          ? const LoadingIndicator()
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.delete_outline,
                      title: 'Trash is empty',
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.only(top: 4),
                        itemCount: _items.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  16, 8, 16, 4),
                              child: Text(
                                _retentionDays == null
                                    ? 'Deleted items stay here until you remove them.'
                                    : _retentionDays == 0
                                        ? 'Deleted items stay here until you remove them.'
                                        : 'Deleted items recover here for $_retentionDays days, then vanish forever.',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline,
                                    ),
                              ),
                            );
                          }
                          final file = _items[i - 1];
                          return ListTile(
                            leading: VaultFileIcon(
                                name: file.name,
                                isFolder: file.isFolder,
                                size: 36),
                            title: Text(file.name),
                            subtitle: Text(
                              file.deletedAt == null
                                  ? 'In trash'
                                  : 'Deleted ${formatRelative(file.deletedAt!)}',
                            ),
                            trailing: PopupMenuButton(
                              tooltip: 'Actions for ${file.name}',
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'restore',
                                  child: Text('Restore'),
                                ),
                                const PopupMenuItem(
                                  value: 'permanent',
                                  child: Text('Delete Permanently',
                                      style: TextStyle(color: Colors.red)),
                                ),
                              ],
                              onSelected: (value) {
                                if (value == 'restore') _restore(file);
                                if (value == 'permanent') _permanentDelete(file);
                              },
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}