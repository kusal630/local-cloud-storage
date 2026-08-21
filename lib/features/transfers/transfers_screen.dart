import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/transfer_manager.dart';
import 'package:localvault/widgets/common.dart';

class TransfersScreen extends ConsumerWidget {
  const TransfersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager = ref.watch(transferManagerProvider);
    final tasks = manager.tasks;
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transfers'),
        actions: [
          if (tasks.any((t) => t.status == TransferStatus.completed))
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: 'Clear Completed',
              onPressed: manager.clearCompleted,
            ),
        ],
      ),
      body: tasks.isEmpty
          ? const EmptyState(
              icon: Icons.swap_vert_circle_outlined,
              title: 'No transfers',
              subtitle: 'Upload and download progress will appear here.',
            )
          : ListView.builder(
              itemCount: tasks.length,
              itemBuilder: (context, i) {
                final task = tasks[i];
                final progress = task.totalBytes > 0
                    ? task.transferredBytes / task.totalBytes
                    : 0.0;
                final isUpload = task.type == TransferType.upload;

                return Card(
                  margin:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: ListTile(
                    leading: Icon(
                      isUpload
                          ? Icons.cloud_upload_outlined
                          : Icons.cloud_download_outlined,
                      color: _statusColor(task.status, colors),
                    ),
                    title: Text(task.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(
                          value: progress,
                          color: _statusColor(task.status, colors),
                          backgroundColor: colors.surfaceContainerHighest,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(
                              '${formatBytes(task.transferredBytes)} / ${formatBytes(task.totalBytes)}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const Spacer(),
                            Text(
                              _statusLabel(task.status),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: _statusColor(task.status, colors),
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    trailing: _buildAction(task, manager),
                  ),
                );
              },
            ),
    );
  }

  Widget? _buildAction(TransferTask task, TransferManager manager) {
    switch (task.status) {
      case TransferStatus.queued:
      case TransferStatus.running:
        return IconButton(
          icon: const Icon(Icons.cancel),
          tooltip: 'Cancel',
          onPressed: () => manager.cancel(task.id),
        );
      case TransferStatus.failed:
      case TransferStatus.cancelled:
        return IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Retry',
          onPressed: () => manager.retry(task.id),
        );
      case TransferStatus.completed:
        return const Icon(Icons.check_circle, color: Colors.green);
    }
  }

  Color _statusColor(TransferStatus s, ColorScheme c) {
    switch (s) {
      case TransferStatus.queued:
        return c.outline;
      case TransferStatus.running:
        return c.primary;
      case TransferStatus.completed:
        return Colors.green;
      case TransferStatus.failed:
        return c.error;
      case TransferStatus.cancelled:
        return c.outlineVariant;
    }
  }

  String _statusLabel(TransferStatus s) {
    switch (s) {
      case TransferStatus.queued:
        return 'Queued';
      case TransferStatus.running:
        return 'Uploading...';
      case TransferStatus.completed:
        return 'Done';
      case TransferStatus.failed:
        return 'Failed';
      case TransferStatus.cancelled:
        return 'Cancelled';
    }
  }
}