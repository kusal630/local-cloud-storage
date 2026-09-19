import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';
import 'common.dart';

/// Sync conflict information.
class SyncConflict {
  const SyncConflict({
    required this.fileId,
    required this.fileName,
    required this.localModified,
    required this.remoteModified,
    required this.localSize,
    required this.remoteSize,
  });

  final String fileId;
  final String fileName;
  final DateTime localModified;
  final DateTime remoteModified;
  final int localSize;
  final int remoteSize;

  bool get localIsNewer => localModified.isAfter(remoteModified);
  bool get remoteIsNewer => remoteModified.isAfter(localModified);
}

/// Conflict resolution dialog.
class ConflictResolver extends StatelessWidget {
  const ConflictResolver({
    super.key,
    required this.conflicts,
    required this.onResolve,
    required this.onResolveAll,
  });

  final List<SyncConflict> conflicts;
  final ValueChanged<ConflictResolution> onResolve;
  final ValueChanged<ConflictResolution> onResolveAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Icon(Icons.warning_rounded, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Text(
                '${conflicts.length} Sync Conflict(s)',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: Colors.orange,
                    ),
              ),
            ],
          ),
        ),
        // Quick resolve all
        if (conflicts.length > 1)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      AppHaptics.medium();
                      onResolveAll(ConflictResolution.keepLocal);
                    },
                    icon: const Icon(Icons.phone_android_rounded, size: 16),
                    label: const Text('Keep all local'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      AppHaptics.medium();
                      onResolveAll(ConflictResolution.keepRemote);
                    },
                    icon: const Icon(Icons.cloud_rounded, size: 16),
                    label: const Text('Keep all remote'),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        // Conflict list
        Expanded(
          child: ListView.builder(
            itemCount: conflicts.length,
            itemBuilder: (context, index) {
              final conflict = conflicts[index];
              return _ConflictTile(
                conflict: conflict,
                onResolve: onResolve,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ConflictTile extends StatelessWidget {
  const _ConflictTile({
    required this.conflict,
    required this.onResolve,
  });

  final SyncConflict conflict;
  final ValueChanged<ConflictResolution> onResolve;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File name
            Text(
              conflict.fileName,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 12),
            // Comparison
            Row(
              children: [
                // Local
                Expanded(
                  child: _VersionInfo(
                    label: 'Local',
                    date: conflict.localModified,
                    size: conflict.localSize,
                    isNewer: conflict.localIsNewer,
                    icon: Icons.phone_android_rounded,
                  ),
                ),
                // VS
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    'VS',
                    style: TextStyle(
                      color: scheme.outline,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                // Remote
                Expanded(
                  child: _VersionInfo(
                    label: 'Remote',
                    date: conflict.remoteModified,
                    size: conflict.remoteSize,
                    isNewer: conflict.remoteIsNewer,
                    icon: Icons.cloud_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Resolution buttons
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      AppHaptics.medium();
                      onResolve(ConflictResolution.keepLocal);
                    },
                    icon: const Icon(Icons.phone_android_rounded, size: 16),
                    label: const Text('Keep local'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () {
                      AppHaptics.medium();
                      onResolve(ConflictResolution.keepRemote);
                    },
                    icon: const Icon(Icons.cloud_rounded, size: 16),
                    label: const Text('Keep remote'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VersionInfo extends StatelessWidget {
  const _VersionInfo({
    required this.label,
    required this.date,
    required this.size,
    required this.isNewer,
    required this.icon,
  });

  final String label;
  final DateTime date;
  final int size;
  final bool isNewer;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: isNewer
            ? scheme.primaryContainer.withValues(alpha: 0.3)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: isNewer
            ? Border.all(color: scheme.primary.withValues(alpha: 0.3))
            : null,
      ),
      child: Column(
        children: [
          Icon(icon, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 2),
          Text(
            '${date.day}/${date.month} ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                  fontSize: 10,
                ),
          ),
          Text(
            formatBytes(size),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                  fontSize: 10,
                ),
          ),
          if (isNewer)
            Text(
              'NEWER',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                  ),
            ),
        ],
      ),
    );
  }
}

/// Conflict resolution action.
enum ConflictResolution {
  keepLocal,
  keepRemote,
  keepBoth,
}
