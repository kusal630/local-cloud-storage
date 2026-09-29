import 'package:flutter/material.dart';

import '../client/services/transfer_manager.dart';
import 'common.dart';

/// A persistent, non-modal strip above the tab bar for work in progress.
///
/// An upload is app-level state, not tab-level state: start a file on Files,
/// switch to Storage, and the transfer and how far along it is must still be
/// visible. Borrowed from Unraid's always-on status bar for exactly that
/// reason — work in progress never hides behind a tab.
///
/// Renders nothing when the queue has nothing to report, so an idle app pays
/// no layout cost for it.
class ActivityStrip extends StatelessWidget {
  const ActivityStrip({required this.tasks, required this.onOpen, super.key});

  final List<TransferTask> tasks;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final running = tasks
        .where((t) => t.status == TransferStatus.running)
        .toList(growable: false);
    final queued =
        tasks.where((t) => t.status == TransferStatus.queued).length;
    if (running.isEmpty && queued == 0) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final styles = Theme.of(context).textTheme;
    final uploading =
        running.isEmpty || running.first.type == TransferType.upload;

    final String label;
    if (running.isEmpty) {
      // Nothing is moving yet, so say waiting rather than implying progress.
      label = queued == 1
          ? 'One file waiting to upload'
          : '$queued files waiting to upload';
    } else if (running.length == 1) {
      label =
          '${uploading ? 'Uploading' : 'Downloading'} ${running.first.name}';
    } else {
      // `${}` is required: `$running.length` interpolates the list itself and
      // then prints the literal ".length".
      label =
          '${uploading ? 'Uploading' : 'Downloading'} ${running.length} files';
    }

    var total = 0;
    var done = 0;
    for (final t in running) {
      total += t.totalBytes;
      done += t.transferredBytes;
    }
    // null only when something is running at an unknown size: an honest
    // "moving, size unknown" beats a percentage the app cannot compute.
    final double? fraction = running.isEmpty
        ? 0
        : total > 0
            ? (done / total).clamp(0.0, 1.0)
            : null;

    // Aggregate throughput, so two parallel transfers read as one stream of
    // work rather than whichever one happened to tick last.
    final speedBps =
        running.fold<double>(0, (sum, t) => sum + t.speedBps);
    final trailing = <String>[
      if (speedBps > 0) '${formatBytes(speedBps.round())}/s',
      if (fraction != null && running.isNotEmpty)
        '${(fraction * 100).round()}%',
    ].join(' · ');

    return Semantics(
      container: true,
      button: true,
      label: 'Open transfers',
      child: Material(
        color: scheme.surfaceContainer,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 3,
                child: fraction == null
                    ? const LinearProgressIndicator(minHeight: 3)
                    : LinearProgressIndicator(value: fraction, minHeight: 3),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      running.isEmpty
                          ? Icons.schedule_rounded
                          : uploading
                              ? Icons.upload_rounded
                              : Icons.download_rounded,
                      size: 18,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: styles.bodyMedium,
                      ),
                    ),
                    if (trailing.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Text(
                        trailing,
                        style: styles.labelMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
