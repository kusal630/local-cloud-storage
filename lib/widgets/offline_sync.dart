import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';
import 'common.dart';

/// Sync status for a file or folder.
enum SyncStatus {
  synced('Synced', Icons.cloud_done_rounded, Colors.green),
  syncing('Syncing...', Icons.sync_rounded, Colors.blue),
  pending('Pending', Icons.schedule_rounded, Colors.orange),
  error('Error', Icons.error_rounded, Colors.red),
  offline('Offline', Icons.cloud_off_rounded, Colors.grey);

  const SyncStatus(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

/// Sync status indicator widget.
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({
    super.key,
    required this.status,
    this.showLabel = true,
  });

  final SyncStatus status;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: status.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 14, color: status.color),
          if (showLabel) ...[
            const SizedBox(width: 4),
            Text(
              status.label,
              style: TextStyle(
                fontSize: 11,
                color: status.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Sync progress indicator.
class SyncProgress extends StatelessWidget {
  const SyncProgress({
    super.key,
    required this.current,
    required this.total,
    this.currentFile,
  });

  final int current;
  final int total;
  final String? currentFile;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = total > 0 ? current / total : 0.0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Syncing $current of $total files',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ],
          ),
          if (currentFile != null) ...[
            const SizedBox(height: 8),
            Text(
              currentFile!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Offline files manager widget.
class OfflineFileManager extends StatelessWidget {
  const OfflineFileManager({
    super.key,
    required this.files,
    required this.onUnpin,
    required this.onClearAll,
  });

  final List<OfflineFile> files;
  final ValueChanged<String> onUnpin;
  final VoidCallback onClearAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final totalSize = files.fold(0, (sum, f) => sum + f.size);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Offline Files',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              Text(
                '${files.length} files • ${formatBytes(totalSize)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              if (files.isNotEmpty) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.delete_sweep_rounded, size: 20),
                  tooltip: 'Clear all offline files',
                  onPressed: () {
                    AppHaptics.heavy();
                    _showClearAllDialog(context);
                  },
                ),
              ],
            ],
          ),
        ),
        // File list
        Expanded(
          child: files.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_rounded,
                          size: 48, color: Colors.grey),
                      SizedBox(height: 16),
                      Text('No offline files'),
                      SizedBox(height: 8),
                      Text(
                        'Pin files to access them without the host.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: files.length,
                  itemBuilder: (context, index) {
                    final file = files[index];
                    return ListTile(
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(Icons.file_present_rounded,
                            color: scheme.onPrimaryContainer, size: 20),
                      ),
                      title: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(formatBytes(file.size)),
                      trailing: IconButton(
                        icon: const Icon(Icons.cloud_upload_rounded, size: 20),
                        tooltip: 'Remove offline copy',
                        onPressed: () {
                          AppHaptics.medium();
                          onUnpin(file.id);
                        },
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showClearAllDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all offline files?'),
        content: const Text(
          'This will remove all pinned files from this device. '
          'Files will still be available on the host.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              AppHaptics.heavy();
              Navigator.pop(ctx);
              onClearAll();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
  }
}

/// Offline file data.
class OfflineFile {
  const OfflineFile({
    required this.id,
    required this.name,
    required this.size,
  });

  final String id;
  final String name;
  final int size;
}
