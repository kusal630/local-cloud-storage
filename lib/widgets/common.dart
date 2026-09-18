import 'package:flutter/material.dart';

class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key, this.message});
  final String? message;
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator.adaptive(),
            if (message != null) ...[
              const SizedBox(height: 16),
              Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              if (subtitle != null) ...[
                const SizedBox(height: 8),
                Text(subtitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                    textAlign: TextAlign.center),
              ],
              if (action != null) ...[
                const SizedBox(height: 24),
                action!,
              ],
            ],
          ),
        ),
      );
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.errorContainer.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.error_outline,
                  size: 40, color: colors.onErrorContainer),
            ),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Brand mark: vault glyph in a rounded gradient tile.
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Icon(Icons.cloud_off_outlined,
          size: size * 0.5, color: scheme.onPrimary),
    );
  }
}

/// Section heading with optional trailing action.
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.action});
  final String title;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ),
            if (action != null) action!,
          ],
        ),
      );
}

/// File-type icon with per-type tint. Pass file name + folder flag.
class VaultFileIcon extends StatelessWidget {
  const VaultFileIcon(
      {super.key, required this.name, this.isFolder = false, this.size = 40});
  final String name;
  final bool isFolder;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (isFolder) {
      return _tile(scheme.primary, scheme.onPrimary, Icons.folder_rounded);
    }
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'bmp']
        .contains(ext)) {
      return _tile(const Color(0xFF7C4DFF), Colors.white, Icons.image_rounded);
    }
    if (['mp4', 'mkv', 'mov', 'avi', 'webm'].contains(ext)) {
      return _tile(const Color(0xFFE040FB), Colors.white, Icons.movie_rounded);
    }
    if (['mp3', 'wav', 'flac', 'ogg', 'm4a'].contains(ext)) {
      return _tile(const Color(0xFF00ACC1), Colors.white, Icons.audio_file_rounded);
    }
    if (['pdf'].contains(ext)) {
      return _tile(const Color(0xFFE53935), Colors.white,
          Icons.picture_as_pdf_rounded);
    }
    if (['zip', 'rar', '7z', 'tar', 'gz'].contains(ext)) {
      return _tile(const Color(0xFFFB8C00), Colors.white, Icons.archive_rounded);
    }
    if (['doc', 'docx', 'txt', 'md', 'rtf'].contains(ext)) {
      return _tile(scheme.tertiary, scheme.onTertiary, Icons.description_rounded);
    }
    if (['xls', 'xlsx', 'csv'].contains(ext)) {
      return _tile(const Color(0xFF43A047), Colors.white, Icons.table_chart_rounded);
    }
    if (['apk', 'exe', 'dmg', 'deb'].contains(ext)) {
      return _tile(scheme.secondary, scheme.onSecondary,
          Icons.apps_rounded);
    }
    return _tile(scheme.surfaceContainerHighest, scheme.onSurfaceVariant,
        Icons.insert_drive_file_rounded);
  }

  Widget _tile(Color bg, Color fg, IconData icon) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(icon, size: size * 0.55, color: bg),
      );
}

/// Linear storage meter with labels.
class StorageMeter extends StatelessWidget {
  const StorageMeter({
    super.key,
    required this.fraction,
    required this.usedLabel,
    this.freeLabel,
    this.color,
  });
  final double fraction;
  final String usedLabel;
  final String? freeLabel;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 10,
            color: color ?? scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(usedLabel, style: Theme.of(context).textTheme.bodySmall),
            if (freeLabel != null)
              Text(freeLabel!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// Skeleton placeholder row for loading lists.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6});
  final int rows;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rows,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, _) => Container(
        height: 64,
        decoration: BoxDecoration(
            color: c.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

/// Small status pill (e.g. Running / Paired / LAN-only).
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 8, height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                )),
          ],
        ),
      );
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes < 1024 * 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / (1024 * 1024 * 1024 * 1024)).toStringAsFixed(1)} TB';
}

/// Short human date: "12 Sep 2026, 14:30" or "Today 14:30".
String formatDateTime(DateTime dt) {
  final local = dt.toLocal();
  final now = DateTime.now();
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  final sameDay = local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
  if (sameDay) return 'Today $time';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}, $time';
}

/// Relative time ("just now", "5m ago", "Yesterday") — recency beats
/// timestamps for scanning lists (peak attention on what's new).
String formatRelative(DateTime dt) {
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.isNegative) return 'just now';
  if (diff.inSeconds < 45) return 'just now';
  if (diff.inMinutes < 1) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return formatDateTime(dt);
}

String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
  return '${d.inSeconds}s';
}