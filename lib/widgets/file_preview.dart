import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../core/haptics/haptic_feedback.dart';
import 'common.dart';

/// Enhanced image viewer with pinch-to-zoom, double-tap zoom,
/// and smooth transitions.
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.imageProvider,
    this.heroTag,
    this.onShare,
    this.onDownload,
    this.onInfo,
  });

  final ImageProvider imageProvider;
  final String? heroTag;
  final VoidCallback? onShare;
  final VoidCallback? onDownload;
  final VoidCallback? onInfo;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer>
    with SingleTickerProviderStateMixin {
  late final TransformationController _controller;
  late final AnimationController _animController;
  final double _scale = 1.0;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _controller = TransformationController();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _toggleControls() {
    AppHaptics.light();
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Image with gesture detection
          GestureDetector(
            onTap: _toggleControls,
            child: InteractiveViewer(
              transformationController: _controller,
              minScale: 0.5,
              maxScale: 5.0,
              child: Center(
                child: widget.heroTag != null
                    ? Hero(
                        tag: widget.heroTag!,
                        child: Image(
                          image: widget.imageProvider,
                          fit: BoxFit.contain,
                        ),
                      )
                    : Image(
                        image: widget.imageProvider,
                        fit: BoxFit.contain,
                      ),
              ),
            ),
          ),
          // Controls overlay
          if (_showControls)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.7),
                      Colors.transparent,
                    ],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    if (widget.onShare != null)
                      IconButton(
                        icon: const Icon(Icons.share_rounded,
                            color: Colors.white),
                        onPressed: widget.onShare,
                      ),
                    if (widget.onDownload != null)
                      IconButton(
                        icon: const Icon(Icons.download_rounded,
                            color: Colors.white),
                        onPressed: widget.onDownload,
                      ),
                    if (widget.onInfo != null)
                      IconButton(
                        icon: const Icon(Icons.info_outline_rounded,
                            color: Colors.white),
                        onPressed: widget.onInfo,
                      ),
                  ],
                ),
              ).animate().fadeIn(duration: 200.ms),
            ),
          // Zoom indicator
          Positioned(
            bottom: 100,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${(_scale * 100).round()}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Video player controls overlay.
class VideoControls extends StatelessWidget {
  const VideoControls({
    super.key,
    required this.isPlaying,
    required this.position,
    required this.duration,
    required this.onPlayPause,
    required this.onSeek,
    this.onFullscreen,
  });

  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback? onFullscreen;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.8),
          ],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Progress bar
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: Theme.of(context).colorScheme.primary,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.3),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: duration.inMilliseconds > 0
                  ? position.inMilliseconds / duration.inMilliseconds
                  : 0.0,
              onChanged: (value) {
                final newPos = Duration(
                  milliseconds: (value * duration.inMilliseconds).round(),
                );
                onSeek(newPos);
              },
            ),
          ),
          // Controls row
          Row(
            children: [
              Text(
                _formatDuration(position),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(
                  isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 36,
                ),
                onPressed: onPlayPause,
              ),
              const Spacer(),
              Text(
                _formatDuration(duration),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
              ),
              if (onFullscreen != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.fullscreen_rounded,
                      color: Colors.white),
                  onPressed: onFullscreen,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }
}

/// File info panel with metadata.
class FileInfoPanel extends StatelessWidget {
  const FileInfoPanel({
    super.key,
    required this.name,
    required this.size,
    required this.modifiedAt,
    this.createdAt,
    this.mimeType,
    this.checksum,
    this.path,
  });

  final String name;
  final int size;
  final DateTime modifiedAt;
  final DateTime? createdAt;
  final String? mimeType;
  final String? checksum;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: scheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            name,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 16),
          _InfoRow(label: 'Size', value: formatBytes(size)),
          _InfoRow(
              label: 'Modified',
              value: formatDateTime(modifiedAt)),
          if (createdAt != null)
            _InfoRow(
                label: 'Created',
                value: formatDateTime(createdAt!)),
          if (mimeType != null) _InfoRow(label: 'Type', value: mimeType!),
          if (checksum != null) ...[
            const SizedBox(height: 8),
            Text(
              'Checksum',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                checksum!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
          ],
          if (path != null) ...[
            const SizedBox(height: 8),
            Text(
              'Path',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  ),
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                path!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                    ),
              ),
            ),
          ],
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}
