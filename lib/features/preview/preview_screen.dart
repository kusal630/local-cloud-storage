import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/file_service.dart';
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
          ? _PreviewImage(fileId: file.id)
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
  final String fileId;
  const _PreviewImage({required this.fileId});
  @override
  ConsumerState<_PreviewImage> createState() => _PreviewImageState();
}

class _PreviewImageState extends ConsumerState<_PreviewImage> {
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final b = await ref.read(fileServiceProvider).thumbBytes(widget.fileId);
      setState(() => _bytes = Uint8List.fromList(b));
    } catch (_) {
      try {
        final b =
            await ref.read(fileServiceProvider).downloadBytes(widget.fileId);
        setState(() => _bytes = Uint8List.fromList(b));
      } catch (e) {
        setState(() => _error = e.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return ErrorState(message: 'Could not load image.', onRetry: _load);
    }
    if (_bytes == null) {
      return const LoadingIndicator();
    }
    return InteractiveViewer(
      child: Center(child: Image.memory(_bytes!, fit: BoxFit.contain)),
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

  Future<void> _restoreVersion(FileVersion v) async {
    final confirmed = await showDialog<bool>(
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
          const SectionHeader(title: 'VERSION HISTORY'),
          if (_versions == null)
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