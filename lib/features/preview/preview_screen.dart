import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
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
      final parentId = ref.read(currentFolderProvider);
      final items = await svc.listFiles(parentId);
      final match = items.where((f) => f.id == widget.fileId).firstOrNull;
      setState(() {
        _file = match;
        _loading = false;
      });
    } catch (e) {
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
            icon: const Icon(Icons.download),
            tooltip: 'Download',
            onPressed: () async {
              ref.read(transferManagerProvider).enqueueDownload(
                    fileId: file.id,
                    name: file.name,
                    destDir: '/tmp',
                    totalBytes: file.size,
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

class _PreviewMetadata extends StatelessWidget {
  final VaultFile file;
  const _PreviewMetadata({required this.file});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.insert_drive_file,
            size: 64, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 16),
        Text(file.name,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center),
        const SizedBox(height: 24),
        Card(
          child: Column(
            children: [
              _infoRow('Type', file.isFolder ? 'Folder' : 'File'),
              _infoRow('MIME', file.mime ?? 'Unknown'),
              _infoRow('Size', formatBytes(file.size)),
              _infoRow('Created', file.createdAt.toLocal().toString()),
              _infoRow('Modified', file.modifiedAt.toLocal().toString()),
              if (file.checksum != null)
                _infoRow('SHA-256', '${file.checksum!.substring(0, 16)}...'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _infoRow(String label, String value) => ListTile(
        dense: true,
        title: Text(label),
        subtitle: Text(value),
      );
}