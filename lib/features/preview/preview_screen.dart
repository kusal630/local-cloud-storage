import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfx/pdfx.dart';
import 'package:video_player/video_player.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/data/models/audit_entry.dart';
import 'package:localvault/data/models/file_comment.dart';
import 'package:localvault/data/models/file_version.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/widgets/common.dart';

class PreviewScreen extends ConsumerStatefulWidget {
  const PreviewScreen({required this.fileId, super.key});
  final String fileId;

  @override
  ConsumerState<PreviewScreen> createState() => _PreviewScreenState();
}

class _PreviewScreenState extends ConsumerState<PreviewScreen> {
  VaultFile? _file;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final svc = ref.read(fileServiceProvider);
      // Record recency (best-effort; never blocks preview).
      unawaited(() async {
        try {
          await svc.touchOpen(widget.fileId);
        } catch (_) {}
      }());
      final parentId = ref.read(currentFolderProvider);
      final items = await svc.listFiles(parentId);
      final match = items.where((f) => f.id == widget.fileId).firstOrNull;
      if (!mounted) return;
      setState(() {
        _file = match;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Preview')),
        body: const LoadingIndicator(),
      );
    }
    if (_error != null || _file == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Preview')),
        body: ErrorState(message: _error ?? 'File not found.', onRetry: _load),
      );
    }
    final file = _file!;
    final isImage = file.mime?.startsWith('image/') == true;
    final isPdf = file.mime == 'application/pdf' ||
        file.name.toLowerCase().endsWith('.pdf');
    final isVideo =
        file.mime?.startsWith('video/') == true;
    final isAudio =
        file.mime?.startsWith('audio/') == true;

    return Scaffold(
      appBar: AppBar(
        title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Download',
            onPressed: () async {
              final dir = await FilePicker.getDirectoryPath(
                  dialogTitle: 'Choose download folder');
              if (dir == null) return;
              ref.read(transferManagerProvider).enqueueDownload(
                    fileId: file.id,
                    name: file.name,
                    destDir: dir,
                    totalBytes: file.size,
                    checksum: file.checksum,
                  );
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Download queued: ${file.name}')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            tooltip: 'Rename',
            onPressed: () => _rename(file),
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete',
            onPressed: () => _delete(file),
          ),
        ],
      ),
      body: isImage
          ? _PreviewImage(file: file)
          : isPdf
              ? _PreviewPdf(file: file)
              : isVideo
                  ? _PreviewVideo(file: file)
                  : isAudio
                      ? _PreviewAudio(file: file)
                      : _PreviewMetadata(file: file),
    );
  }

  Future<void> _rename(VaultFile file) async {
    final controller = TextEditingController(text: file.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Rename')),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == file.name) return;
    try {
      await ref.read(fileServiceProvider).renameFile(file.id, name);
      if (mounted) context.go('/client/files');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      }
    }
  }

  Future<void> _delete(VaultFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete?'),
        content: Text('Move "${file.name}" to trash?'),
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
      await ref.read(fileServiceProvider).deleteFile(file.id);
      if (mounted) context.go('/client/files');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }
}

class _PreviewImage extends ConsumerStatefulWidget {
  final VaultFile file;
  const _PreviewImage({required this.file});
  @override
  ConsumerState<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends ConsumerState<_PreviewImage> {
  Uint8List? _bytes;
  String? _error;
  String? _dims;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await ref.read(fileServiceProvider).thumbBytes(widget.file.id);
      if (!mounted) return;
      setState(() => _bytes = Uint8List.fromList(b));
      final dims = await compute(_imageDims, b);
      if (!mounted) return;
      setState(() => _dims = dims);
    } catch (_) {
      if (!mounted) return;
      try {
        final b = await ref
            .read(fileServiceProvider)
            .downloadBytes(widget.file.id);
        if (!mounted) return;
        setState(() => _bytes = Uint8List.fromList(b));
        final dims = await compute(_imageDims, b);
        if (!mounted) return;
        setState(() => _dims = dims);
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ErrorState(message: 'Could not load image.', onRetry: () {
        setState(() {
          _error = null;
          _bytes = null;
        });
        _load();
      });
    }
    if (_bytes == null) {
      return const LoadingIndicator();
    }
    return Column(
      children: [
        if (_dims != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: StatusPill(
                label: '$_dims • ${formatBytes(widget.file.size)}',
                color: const Color(0xFF0E7C7B)),
          ),
        Expanded(
          child: InteractiveViewer(
            child: Center(
                child: Hero(
              tag: 'thumb-${widget.file.id}',
              child: Image.memory(_bytes!, fit: BoxFit.contain),
            )),
          ),
        ),
      ],
    );
  }
}

String? _imageDims(List<int> bytes) {
  try {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) return null;
    return '${decoded.width}×${decoded.height}';
  } catch (_) {
    return null;
  }
}

/// PDF preview (downloaded over trusted TLS, rendered locally).
/// Falls back to metadata for huge files or unsupported platforms.
class _PreviewPdf extends ConsumerStatefulWidget {
  final VaultFile file;
  const _PreviewPdf({required this.file});
  @override
  ConsumerState<_PreviewPdf> createState() => _PreviewPdfState();
}

class _PreviewPdfState extends ConsumerState<_PreviewPdf> {
  static const int maxBytes = 50 * 1024 * 1024;
  PdfController? _controller;
  String? _error;
  int _pages = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.file.size > maxBytes) {
      if (!mounted) return;
      setState(() => _error = 'too-large');
      return;
    }
    try {
      final bytes =
          await ref.read(fileServiceProvider).downloadBytes(widget.file.id);
      final doc = await PdfDocument.openData(Uint8List.fromList(bytes));
      if (!mounted) return;
      setState(() {
        _controller = PdfController(document: Future.value(doc));
        _pages = doc.pagesCount;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _PreviewMetadata(file: widget.file);
    }
    final controller = _controller;
    if (controller == null) {
      return const LoadingIndicator(message: 'Loading PDF…');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: StatusPill(
              label: 'PDF • $_pages pages',
              color: const Color(0xFFE53935)),
        ),
        Expanded(
          child: PdfView(
            controller: controller,
            scrollDirection: Axis.vertical,
            pageSnapping: false,
            onDocumentError: (_) {
              if (mounted) setState(() => _error = 'render');
            },
          ),
        ),
      ],
    );
  }
}

/// Video preview: fetched over the app's pinned TLS into a temp file, then
/// played locally (platform players reject self-signed certs on streams).
class _PreviewVideo extends ConsumerStatefulWidget {
  final VaultFile file;
  const _PreviewVideo({required this.file});
  @override
  ConsumerState<_PreviewVideo> createState() => _PreviewVideoState();
}

class _PreviewVideoState extends ConsumerState<_PreviewVideo> {
  static const int maxBytes = 200 * 1024 * 1024;
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.file.size > maxBytes) {
      if (!mounted) return;
      setState(() => _error = 'too-large');
      return;
    }
    try {
      final bytes =
          await ref.read(fileServiceProvider).downloadBytes(widget.file.id);
      final dir = await getTemporaryDirectory();
      final path = p.join(
          dir.path, 'preview_${widget.file.id}_${widget.file.name}');
      await File(path).writeAsBytes(bytes);
      final controller = VideoPlayerController.file(File(path));
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _PreviewMetadata(file: widget.file);
    }
    final controller = _controller;
    if (controller == null) {
      return const LoadingIndicator(message: 'Loading video…');
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: controller.value.aspectRatio == 0
                ? 16 / 9
                : controller.value.aspectRatio,
            child: VideoPlayer(controller),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              if (controller.value.isPlaying) {
                controller.pause();
              } else {
                controller.play();
              }
              setState(() {});
            },
            icon: Icon(controller.value.isPlaying
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded),
            label: Text(
                controller.value.isPlaying ? 'Pause' : 'Play'),
          ),
        ],
      ),
    );
  }
}

/// Audio preview with seek bar (same trusted-download pattern as video).
class _PreviewAudio extends ConsumerStatefulWidget {
  final VaultFile file;
  const _PreviewAudio({required this.file});
  @override
  ConsumerState<_PreviewAudio> createState() => _PreviewAudioState();
}

class _PreviewAudioState extends ConsumerState<_PreviewAudio> {
  static const int maxBytes = 100 * 1024 * 1024;
  final AudioPlayer _player = AudioPlayer();
  String? _error;
  bool _ready = false;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<void>? _doneSub;

  @override
  void initState() {
    super.initState();
    _posSub = _player.onPositionChanged.listen((d) {
      if (mounted) setState(() => _position = d);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _doneSub = _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _playing = false);
    });
    _load();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _doneSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.file.size > maxBytes) {
      if (!mounted) return;
      setState(() => _error = 'too-large');
      return;
    }
    try {
      final bytes =
          await ref.read(fileServiceProvider).downloadBytes(widget.file.id);
      final dir = await getTemporaryDirectory();
      final path = p.join(
          dir.path, 'preview_${widget.file.id}_${widget.file.name}');
      await File(path).writeAsBytes(bytes);
      await _player.setSourceDeviceFile(path);
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${d.inHours > 0 ? '${d.inHours}:' : ''}$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _PreviewMetadata(file: widget.file);
    }
    if (!_ready) {
      return const LoadingIndicator(message: 'Loading audio…');
    }
    final max = _duration.inMilliseconds.toDouble();
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              VaultFileIcon(
                  name: widget.file.name, size: 64),
              const SizedBox(height: 12),
              Text(widget.file.name,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 16),
              Row(
                children: [
                  IconButton.filled(
                    icon: Icon(_playing
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                    onPressed: () async {
                      if (_playing) {
                        await _player.pause();
                      } else {
                        await _player.resume();
                      }
                      if (!mounted) return;
                      setState(() => _playing = !_playing);
                    },
                  ),
                  const SizedBox(width: 8),
                  Text(_fmt(_position),
                      style: Theme.of(context).textTheme.bodySmall),
                  Expanded(
                    child: Slider(
                      value: max <= 0
                          ? 0
                          : _position.inMilliseconds
                              .toDouble()
                              .clamp(0, max),
                      max: max <= 0 ? 1 : max,
                      onChanged: (v) => _player.seek(
                          Duration(milliseconds: v.round())),
                    ),
                  ),
                  Text(_fmt(_duration),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewMetadata extends ConsumerStatefulWidget {
  final VaultFile file;
  const _PreviewMetadata({required this.file});

  @override
  ConsumerState<_PreviewMetadata> createState() => _PreviewMetadataState();
}

class _PreviewMetadataState extends ConsumerState<_PreviewMetadata> {
  List<FileVersion>? _versions;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    if (widget.file.isFolder) return;
    try {
      final versions =
          await ref.read(fileServiceProvider).listVersions(widget.file.id);
      if (!mounted) return;
      setState(() => _versions = versions);
    } catch (_) {}
  }

  Future<void> _restoreVersion(FileVersion v) async {    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restore v${v.version}?'),
        content: Text(
            'Current content will be archived as a new version first, so nothing is lost.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(fileServiceProvider)
          .restoreVersion(widget.file.id, v.version);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Restored v${v.version}')),
      );
      _loadVersions();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;
    final previewable =
        !file.isFolder && FileService.isTextPreviewable(file.name, file.mime);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Center(
            child: VaultFileIcon(
                name: file.name, isFolder: file.isFolder, size: 72)),
        const SizedBox(height: 16),
        Text(file.name,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center),
        if (previewable) ...[
          const SizedBox(height: 16),
          _PreviewTextCard(fileId: file.id, fileName: file.name),
        ],
        if (file.isFavorite)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Center(
              child: StatusPill(label: 'STARRED', color: Color(0xFFFB8C00)),
            ),
          ),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              _infoRow(context, 'Type', file.isFolder ? 'Folder' : 'File'),
              _infoRow(context, 'MIME', file.mime ?? 'Unknown'),
              _infoRow(context, 'Size', formatBytes(file.size)),
              _infoRow(context, 'Created', formatDateTime(file.createdAt)),
              _infoRow(context, 'Modified', formatDateTime(file.modifiedAt)),
              if (file.lastOpenedAt != null)
                _infoRow(
                    context, 'Opened', formatDateTime(file.lastOpenedAt!)),
              if (file.checksum != null)
                ListTile(
                  dense: true,
                  title: const Text('SHA-256'),
                  subtitle: Text(
                      '${file.checksum!.substring(0, 16)}… (tap to copy)'),
                  trailing: const Icon(Icons.copy_rounded, size: 18),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: file.checksum!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Checksum copied')),
                    );
                  },
                ),
            ],
          ),
        ),
        if (!file.isFolder) ...[
          const SizedBox(height: 16),
          const SectionHeader(title: 'VERSION HISTORY'),          if (_versions == null)
            const LoadingIndicator()
          else if (_versions!.isEmpty)
            const EmptyState(
              icon: Icons.history_rounded,
              title: 'No older versions',
              subtitle:
                  'Re-uploading this file with Replace archives versions here.',
            )
          else
            Card(
              child: Column(
                children: [
                  for (final v in _versions!)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.history_rounded),
                      title: Text(
                          'v${v.version} • ${formatBytes(v.size)}'),
                      subtitle: Text(formatDateTime(v.createdAt)),
                      trailing: TextButton(
                        onPressed: () => _restoreVersion(v),
                        child: const Text('Restore'),
                      ),
                    ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        _CommentsCard(file: file),
        const SizedBox(height: 16),
        _FileActivityCard(fileId: file.id),
      ],
    );
  }

  Widget _infoRow(BuildContext context, String label, String value) =>
      ListTile(
        dense: true,
        title: Text(label),
        subtitle: Text(value),
      );
}

/// Comments on a file (Nextcloud-style details activity).
class _CommentsCard extends ConsumerStatefulWidget {
  final VaultFile file;
  const _CommentsCard({required this.file});
  @override
  ConsumerState<_CommentsCard> createState() => _CommentsCardState();
}

class _CommentsCardState extends ConsumerState<_CommentsCard> {
  List<FileComment>? _comments;
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await ref
          .read(fileServiceProvider)
          .listComments(widget.file.id);
      if (!mounted) return;
      setState(() => _comments = comments);
    } catch (_) {}
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    // Optimistic: show the comment instantly, reconcile on failure.
    final optimistic = FileComment(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      fileId: widget.file.id,
      author: 'you',
      body: text,
      createdAt: DateTime.now(),
    );
    setState(() {
      _sending = true;
      _comments = [...?_comments, optimistic];
    });
    _controller.clear();
    HapticFeedback.lightImpact();
    try {
      await ref
          .read(fileServiceProvider)
          .addComment(widget.file.id, text);
      await _load();
    } catch (e) {
      // Roll back the optimistic row.
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Comment failed: $e')));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _delete(FileComment c) async {
    try {
      await ref
          .read(fileServiceProvider)
          .deleteComment(widget.file.id, c.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
                title:
                    'COMMENTS${_comments == null ? '' : ' (${_comments!.length})'}'),
            if (_comments == null)
              const LoadingIndicator()
            else if (_comments!.isEmpty)
              Text('No comments yet — start the discussion.',
                  style: Theme.of(context).textTheme.bodySmall)
            else
              for (final c in _comments!)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.comment_rounded, size: 20),
                  title: Text(c.body),
                  subtitle: Text(
                      '${c.author} • ${formatRelative(c.createdAt)}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () => _delete(c),
                  ),
                ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                        hintText: 'Add a comment…'),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  icon: _sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded),
                  onPressed: _send,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-file activity from the host audit log.
class _FileActivityCard extends ConsumerStatefulWidget {
  final String fileId;
  const _FileActivityCard({required this.fileId});
  @override
  ConsumerState<_FileActivityCard> createState() =>
      _FileActivityCardState();
}

class _FileActivityCardState
    extends ConsumerState<_FileActivityCard> {
  List<AuditEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final entries = await ref
          .read(fileServiceProvider)
          .activityFor(widget.fileId, limit: 20);
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (_entries == null || _entries!.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'ACTIVITY'),
            for (final e in _entries!)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    const Icon(Icons.timeline_rounded, size: 20),
                title: Text(e.action,
                    style: Theme.of(context).textTheme.bodyMedium),
                subtitle: Text(
                    '${e.targetName ?? ''} • ${formatRelative(e.createdAt)}'
                        .trim(),
                    style: Theme.of(context).textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// Capped plain-text preview for code/logs/notes (first ~128 KB).
class _PreviewTextCard extends ConsumerStatefulWidget {
  final String fileId;
  final String fileName;
  const _PreviewTextCard({required this.fileId, required this.fileName});
  @override
  ConsumerState<_PreviewTextCard> createState() => _PreviewTextCardState();
}

class _PreviewTextCardState extends ConsumerState<_PreviewTextCard> {
  String? _text;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text =
          await ref.read(fileServiceProvider).previewText(widget.fileId);
      if (!mounted) return;
      setState(() => _text = text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ErrorState(message: 'Text preview failed.', onRetry: () {
        setState(() => _error = null);
        _load();
      });
    }
    if (_text == null) return const LoadingIndicator();
    final lines = _text!.split('\n');
    final shown = lines.take(60).join('\n');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'PREVIEW'),
            SelectableText(
              shown,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontFamilyFallback: ['Courier'],
                fontSize: 12,
              ),
            ),
            if (lines.length > 60)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '… ${lines.length - 60} more lines — download for the full file.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}