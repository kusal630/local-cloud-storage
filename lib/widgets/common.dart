import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_animate/flutter_animate.dart';

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

/// Centered failure panel: one plain-language message, an optional retry and
/// secondary action, and an optional collapsed "Technical details" drawer.
///
/// The contract (DESIGN §10, UX_BENCHMARK #13): [message] names the cause and
/// the next step in sentence case and never contains an exception string —
/// the raw text goes in [details], behind a disclosure, so a support ticket
/// can carry it without a user ever having to read it.
class ErrorState extends StatefulWidget {
  const ErrorState({
    super.key,
    required this.message,
    this.onRetry,
    this.details,
    this.secondaryLabel,
    this.onSecondary,
  }) : assert(onSecondary == null || secondaryLabel != null);

  /// Friendly primary copy. No exception strings here.
  final String message;

  /// Primary action — almost always "Retry".
  final VoidCallback? onRetry;

  /// Raw technical text (exception, status code, endpoint) for support,
  /// hidden behind the collapsed disclosure.
  final String? details;

  /// Label for a second, non-retry action (e.g. "Open help", "Check host").
  final String? secondaryLabel;

  /// Secondary action handler; renders an [OutlinedButton] when set.
  final VoidCallback? onSecondary;

  @override
  State<ErrorState> createState() => _ErrorStateState();
}

class _ErrorStateState extends State<ErrorState> {
  /// Collapsed by default — the technical text is opt-in, never the default
  /// reading (the primary message has to be understood without it).
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
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
            Text(widget.message,
                textAlign: TextAlign.center, style: text.bodyMedium),
            if (widget.onRetry != null || widget.onSecondary != null) ...[
              const SizedBox(height: 16),
              // Wrap, not Row: with large text (or the test font) two buttons
              // side by side overflow instead of reflowing to a second line.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  if (widget.onRetry != null)
                    FilledButton.icon(
                      onPressed: widget.onRetry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  if (widget.onSecondary != null)
                    OutlinedButton(
                      onPressed: widget.onSecondary,
                      child: Text(widget.secondaryLabel!),
                    ),
                ],
              ),
            ],
            if (widget.details != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => setState(() => _showDetails = !_showDetails),
                icon: Icon(
                  _showDetails ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                ),
                label: const Text('Technical details'),
              ),
              if (_showDetails)
                // Theme tokens only (surfaceContainerHighest + outline), so
                // the drawer reads the same in light, dark and AMOLED — no
                // fixed greys to be "corrected" later.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: colors.outlineVariant),
                  ),
                  child: Text(
                    widget.details!,
                    style: text.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                      fontFamily: 'Roboto Mono',
                      fontFamilyFallback: const <String>['monospace'],
                    ),
                  ),
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
          BoxShadow(
            color: scheme.primary.withValues(alpha: 0.15),
            blurRadius: 48,
            offset: const Offset(0, 24),
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

/// Skeleton placeholder rows with a shimmer sweep — reads as alive,
/// not stuck (perceived-performance research).
///
/// The sweep is decoration, so it stops under "remove animations": the rows
/// stay exactly where they are, they just stop moving (DESIGN §8 collapses
/// durations to zero without ever changing layout). NN/g flag animated
/// skeletons as an accessibility problem in their own right, and until now
/// this was the one loading state in the app that ignored the setting.
class SkeletonList extends StatelessWidget {
  const SkeletonList({super.key, this.rows = 6});
  final int rows;
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme.surfaceContainerHighest;
    final still = MediaQuery.disableAnimationsOf(context);
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rows,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final row = Container(
          height: 64,
          decoration: BoxDecoration(
              color: c.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12)),
        );
        return still
            ? row
            : row
                .animate(onPlay: (controller) => controller.repeat())
                .shimmer(duration: 1400.ms, color: c.withValues(alpha: 0.9));
      },
    );
  }
}

/// Small status pill (e.g. Running / Paired / LAN-only).
///
/// Colour and label cross-fade over 200ms `easeInOut` when the state changes
/// (DESIGN §8: *"no bounce, no shake"*). The box, the dot and the label colour
/// all animate so a `DEGRADED → ONLINE` flip reads as one transition rather
/// than a snap — but the pill's geometry never animates, so nothing reflows.
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.label, required this.color});
  final String label;
  final Color color;

  static const Duration _fade = Duration(milliseconds: 200);
  static const Curve _curve = Curves.easeInOut;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.labelMedium;
    return AnimatedContainer(
      duration: _fade,
      curve: _curve,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: _fade,
            curve: _curve,
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          AnimatedSwitcher(
            duration: _fade,
            switchInCurve: _curve,
            switchOutCurve: _curve,
            // Fade only — a slide would read as motion, and §8 asks for a
            // cross-fade. Stacked layout keeps both labels on the same
            // baseline so the dot never shifts sideways mid-transition.
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            child: Text(
              label,
              key: ValueKey(label),
              style: base?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
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

/// Circular storage usage ring — more scannable than a linear bar.
class StorageDonut extends StatelessWidget {
  const StorageDonut({
    super.key,
    required this.fraction,
    required this.usedLabel,
    this.freeLabel,
    this.size = 120,
    this.strokeWidth = 10,
    this.color,
  });
  final double fraction;
  final String usedLabel;
  final String? freeLabel;
  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.primary;
    final clamped = fraction.clamp(0.0, 1.0);
    final pct = (clamped * 100).round();
    // A custom-painted ring announces as "image", or as nothing at all, so a
    // screen-reader user never hears the number (WCAG 1.1.1; DESIGN §10).
    // `status` rather than `progressBar` because this is a reading, not a
    // control — and because `SemanticsRole.status` must not be a live region,
    // it is never re-read on every rebuild.
    return Semantics(
      label: 'Storage in use',
      value: <String>[
        '$pct%',
        if (usedLabel.isNotEmpty) usedLabel,
        if (freeLabel != null && freeLabel!.isNotEmpty) freeLabel!,
      ].join(', '),
      role: SemanticsRole.status,
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: size,
              height: size,
              child: CircularProgressIndicator(
                value: clamped,
                strokeWidth: strokeWidth,
                color: c,
                backgroundColor: scheme.surfaceContainerHighest,
                strokeCap: StrokeCap.round,
              ),
            ),
            // The donut's box is fixed, the text inside it is not: at 200%
            // text scale the labels are taller than the ring and would
            // overflow the centre. `scaleDown` only ever shrinks, so at 100%
            // it lays the labels out exactly as they are now (RESEARCH/
            // UX_BENCHMARK.md item 8).
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$pct%',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: c,
                        ),
                  ),
                  Text(
                    usedLabel,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}