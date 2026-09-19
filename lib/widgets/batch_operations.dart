import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';

/// Batch operation result.
class BatchResult {
  const BatchResult({
    required this.succeeded,
    required this.failed,
    required this.errors,
  });

  final int succeeded;
  final int failed;
  final List<String> errors;

  bool get allSucceeded => failed == 0;
  String get summary =>
      '$succeeded succeeded, $failed failed';
}

/// Batch operations bar for multi-select mode.
class BatchActionBar extends StatelessWidget {
  const BatchActionBar({
    super.key,
    required this.selectedCount,
    required this.onSelectAll,
    required this.onDeselectAll,
    required this.onDelete,
    required this.onMove,
    required this.onCopy,
    required this.onShare,
    this.onDownload,
    this.onTag,
  });

  final int selectedCount;
  final VoidCallback onSelectAll;
  final VoidCallback onDeselectAll;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback? onDownload;
  final VoidCallback? onTag;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Selection info
            Row(
              children: [
                Icon(Icons.check_circle_rounded,
                    color: scheme.onPrimaryContainer, size: 20),
                const SizedBox(width: 8),
                Text(
                  '$selectedCount selected',
                  style: TextStyle(
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: onSelectAll,
                  child: const Text('All'),
                ),
                TextButton(
                  onPressed: onDeselectAll,
                  child: const Text('None'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _BatchAction(
                  icon: Icons.delete_rounded,
                  label: 'Delete',
                  color: scheme.error,
                  onTap: onDelete,
                ),
                _BatchAction(
                  icon: Icons.drive_file_move_rounded,
                  label: 'Move',
                  onTap: onMove,
                ),
                _BatchAction(
                  icon: Icons.copy_rounded,
                  label: 'Copy',
                  onTap: onCopy,
                ),
                _BatchAction(
                  icon: Icons.share_rounded,
                  label: 'Share',
                  onTap: onShare,
                ),
                if (onDownload != null)
                  _BatchAction(
                    icon: Icons.download_rounded,
                    label: 'Download',
                    onTap: onDownload!,
                  ),
                if (onTag != null)
                  _BatchAction(
                    icon: Icons.label_rounded,
                    label: 'Tag',
                    onTap: onTag!,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BatchAction extends StatelessWidget {
  const _BatchAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () {
        AppHaptics.light();
        onTap();
      },
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color ?? scheme.onPrimaryContainer, size: 24),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color ?? scheme.onPrimaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Batch progress indicator for long operations.
class BatchProgress extends StatelessWidget {
  const BatchProgress({
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Processing $current of $total',
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
