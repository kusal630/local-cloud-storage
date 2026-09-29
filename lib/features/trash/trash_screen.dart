import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/core/haptics/haptic_feedback.dart';
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
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        // An exception string is not UI copy — it leaks internals the user
        // cannot act on. Only blank the screen when there is nothing to keep.
        if (_items.isEmpty) {
          _error = "Couldn't load your trash. Tap Retry to try again.";
        }
      });
      if (_items.isNotEmpty) {
        // The list is already on screen: keep it (a spinner would throw away
        // the user's scroll position after every restore) and say so quietly.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not refresh. Pull down to try again.')),
        );
      }
    }
  }

  Future<void> _restore(VaultFile file) async {
    try {
      await ref.read(fileServiceProvider).restoreFile(file.id);
      _load();
      // Restore succeeded *silently* until now: the list just changed under
      // the user with no confirmation that it worked (the failure path always
      // said something — only success was mute).
      // The confirmation doubles as the undo affordance (UX_BENCHMARK #10):
      // the row vanishes from the list, so the way back has to be on screen
      // at the moment it happens.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("'${file.name}' is back in your files."),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => _unrestore(file),
            ),
          ),
        );
      }
      AppHaptics.success();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not restore that file. Pull down to try again.')));
      }
      AppHaptics.error();
    }
  }

  /// Undo of a restore — straight back into the trash, which is exactly what
  /// the files screen's "moved to Trash" snackbar reverses. Undo failures are
  /// said out loud rather than swallowed (never fail quietly).
  Future<void> _unrestore(VaultFile file) async {
    try {
      await ref.read(fileServiceProvider).deleteFile(file.id);
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("'${file.name}' moved back to trash.")),
        );
      }
      AppHaptics.success();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not undo that. Pull down to try again.')));
      }
      AppHaptics.error();
    }
  }

  Future<void> _permanentDelete(VaultFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        // §10: sentence case, and the irreversibility stated plainly.
        title: const Text('Delete permanently?'),
        content: Text(
            '${file.name} will be deleted from this device. This cannot be undone.'),
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
    // §9: heavy feedback fires on the gesture — this is the point of no
    // return, and it fires before the round-trip rather than after it.
    AppHaptics.heavy();
    try {
      await ref.read(fileServiceProvider).permanentDelete(file.id);
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("'${file.name}' was deleted.")),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not delete that file. Pull down to try again.')));
      }
      AppHaptics.error();
    }
  }

  Future<void> _emptyTrash() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty trash?'),
        content: const Text(
            'Everything in the trash will be deleted from this device. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Empty trash')),
        ],
      ),
    );
    if (confirmed != true) return;
    AppHaptics.heavy();
    try {
      await ref.read(fileServiceProvider).emptyTrash();
      _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Trash emptied.')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Could not empty the trash. Pull down to try again.')));
      }
      AppHaptics.error();
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
              tooltip: 'Empty trash',
              onPressed: _emptyTrash,
            ),
        ],
      ),
      body: _loading && _items.isEmpty
          ? const LoadingIndicator()
          : _error != null
              ? ErrorState(message: _error!, onRetry: _load)
              : _items.isEmpty
                  ? const EmptyState(
                      icon: Icons.delete_outline,
                      title: 'Trash is empty',
                      subtitle:
                          'Files you delete appear here first, so you can bring them back.',
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
                              itemBuilder: (ctx) => [
                                const PopupMenuItem(
                                  value: 'restore',
                                  child: Text('Restore'),
                                ),
                                PopupMenuItem(
                                  value: 'permanent',
                                  child: Text(
                                    'Delete permanently',
                                    // Token, not a `Colors.red` literal, so the
                                    // destructive affordance tracks the theme
                                    // (§11: never rely on a fixed hue).
                                    style: TextStyle(
                                      color: Theme.of(ctx).colorScheme.error,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
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