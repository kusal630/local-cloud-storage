import 'dart:async';

import 'dart:async' as async;
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/services/transfer_manager.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});
  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _Crumb {
  final String id;
  final String name;
  const _Crumb(this.id, this.name);
}

/// Grid thumbnail with in-memory cache and icon fallback.
class _GridThumb extends ConsumerStatefulWidget {
  final String fileId;
  const _GridThumb({required this.fileId});
  @override
  ConsumerState<_GridThumb> createState() => _GridThumbState();
}

class _GridThumbState extends ConsumerState<_GridThumb> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    final hit = _cache[widget.fileId];
    if (hit != null) {
      _bytes = hit;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final bytes =
          await ref.read(fileServiceProvider).thumbBytes(widget.fileId);
      if (!mounted) return;
      final data = Uint8List.fromList(bytes);
      _cache[widget.fileId] = data;
      // Bound the cache.
      if (_cache.length > 200) _cache.remove(_cache.keys.first);
      setState(() => _bytes = data);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(_bytes!,
            width: 52, height: 52, fit: BoxFit.cover,
            errorBuilder: (context, error, stackTrace) {
          if (!_failed) setState(() => _failed = true);
          return const SizedBox.shrink();
        }),
      );
    }
    return const SizedBox(
      width: 52,
      height: 52,
      child: Center(
          child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2))),
    );
  }
}

/// Live-sync status: green when the host revision was checked recently.
class _SyncPill extends StatelessWidget {
  const _SyncPill({required this.syncedAt});
  final DateTime? syncedAt;
  @override
  Widget build(BuildContext context) {
    final fresh = syncedAt != null &&
        DateTime.now().difference(syncedAt!) < const Duration(seconds: 30);
    return StatusPill(
      label: syncedAt == null
          ? 'SYNC…'
          : fresh
              ? 'SYNCED'
              : 'STALE',
      color: syncedAt == null
          ? Theme.of(context).colorScheme.outline
          : fresh
              ? const Color(0xFF43A047)
              : const Color(0xFFFB8C00),
    );
  }
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  bool _isGridView = false;
  bool _loading = false;
  List<VaultFile> _items = [];
  String? _error;
  String _sortField = 'name';
  bool _sortAsc = true;
  bool _dragging = false;
  String _query = '';
  String _typeFilter = 'all';
  final Set<String> _selected = {};
  bool _selectionMode = false;
  final List<_Crumb> _crumbs = [const _Crumb('root', 'Home')];
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  async.Timer? _syncTimer;
  async.Timer? _searchTimer;
  int? _syncVersion;
  DateTime? _syncedAt;
  List<VaultFile>? _serverResults;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    _load();
    // Auto-refresh when transfers finish while browsing.
    ref.read(transferManagerProvider).addListener(_onTransfersChanged);
    // Live sync: poll the host revision; reload when it moves.
    _syncTimer =
        async.Timer.periodic(const Duration(seconds: 10), (_) => _pollSync());
    async.unawaited(_pollSync());
  }

  int _doneCount = 0;

  void _onTransfersChanged() {
    if (!mounted) return;
    final manager = ref.read(transferManagerProvider);
    final done = manager.tasks
        .where((t) =>
            t.status == TransferStatus.completed ||
            t.status == TransferStatus.failed)
        .length;
    if (done != _doneCount) {
      _doneCount = done;
      _load();
    }
  }

  Future<void> _pollSync() async {
    try {
      final version = await ref.read(fileServiceProvider).syncVersion();
      if (!mounted) return;
      if (_syncVersion == null) {
        setState(() {
          _syncVersion = version;
          _syncedAt = DateTime.now();
        });
      } else if (version != _syncVersion) {
        setState(() => _syncVersion = version);
        await _load();
        if (!mounted) return;
        setState(() => _syncedAt = DateTime.now());
      }
    } catch (_) {
      // Host unreachable — stay on cached data.
    }
  }

  @override
  void dispose() {
    try {
      ref.read(transferManagerProvider).removeListener(_onTransfersChanged);
    } catch (_) {}
    _syncTimer?.cancel();
    _searchTimer?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _restorePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _isGridView = prefs.getBool('files_grid') ?? false;
        _sortField = prefs.getString('files_sort') ?? 'name';
        _sortAsc = prefs.getBool('files_sort_asc') ?? true;
      });
    } catch (_) {}
  }

  Future<void> _persistPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('files_grid', _isGridView);
      await prefs.setString('files_sort', _sortField);
      await prefs.setBool('files_sort_asc', _sortAsc);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final svc = ref.read(fileServiceProvider);
      final List<VaultFile> items;
      if (_typeFilter == 'starred') {
        items = await svc.listFavorites();
      } else if (_typeFilter == 'recent') {
        items = await svc.listRecent();
      } else if (_typeFilter.startsWith('tag:')) {
        items = await svc.listByTag(_typeFilter.substring(4));
      } else if (_typeFilter == 'offline') {
        items = ref.read(offlineServiceProvider).asVaultFiles();
      } else {
        final folder = ref.read(currentFolderProvider);
        items = await svc.listFiles(folder);
      }
      if (!mounted) return;
      setState(() {
        _items = _sortItems(items);
        _loading = false;
        _selected.clear();
        _selectionMode = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _navigateToFolder(VaultFile folder) {
    ref.read(currentFolderProvider.notifier).state = folder.id;
    setState(() {
      _crumbs.add(_Crumb(folder.id, folder.name));
      _query = '';
      _serverResults = null;
      _searchController.clear();
    });
    _load();
  }

  void _navigateToCrumb(int index) {
    final crumb = _crumbs[index];
    ref.read(currentFolderProvider.notifier).state = crumb.id;
    setState(() {
      _crumbs.removeRange(index + 1, _crumbs.length);
      _query = '';
      _serverResults = null;
      _searchController.clear();
    });
    _load();
  }

  List<VaultFile> _sortItems(List<VaultFile> items) {
    final sorted = List<VaultFile>.from(items);
    sorted.sort((a, b) {
      if (a.isFolder && !b.isFolder) return -1;
      if (!a.isFolder && b.isFolder) return 1;
      int cmp;
      switch (_sortField) {
        case 'size':
          cmp = a.size.compareTo(b.size);
          break;
        case 'date':
          cmp = a.modifiedAt.compareTo(b.modifiedAt);
          break;
        default:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAsc ? cmp : -cmp;
    });
    return sorted;
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      _serverResults = null;
      _searching = false;
    });
    _searchTimer?.cancel();
    final q = value.trim();
    if (q.length < 2) return;
    _searchTimer = async.Timer(const Duration(milliseconds: 400), () async {
      if (!mounted) return;
      setState(() => _searching = true);
      try {
        final results = await ref.read(fileServiceProvider).search(q);
        if (!mounted) return;
        // Drop stale responses.
        if (_searchController.text.trim() != q) return;
        setState(() {
          _serverResults = results;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searching = false);
      }
    });
  }
  List<VaultFile> get _visible {
    final q = _query.trim().toLowerCase();
    // Server-side/global collections; only the query applies.
    if (_typeFilter == 'starred' ||
        _typeFilter == 'recent' ||
        _typeFilter == 'offline' ||
        _typeFilter.startsWith('tag:')) {
      if (q.isEmpty) return _items;
      return _items
          .where((f) => f.name.toLowerCase().contains(q))
          .toList();
    }
    return _items.where((f) {
      if (q.isNotEmpty && !f.name.toLowerCase().contains(q)) return false;
      switch (_typeFilter) {
        case 'folders':
          return f.isFolder;
        case 'images':
          return (f.mime ?? '').startsWith('image/');
        case 'docs':
          final n = f.name.toLowerCase();
          return n.endsWith('.pdf') ||
              n.endsWith('.doc') ||
              n.endsWith('.docx') ||
              n.endsWith('.txt') ||
              n.endsWith('.md');
        case 'video':
          return (f.mime ?? '').startsWith('video/');
        default:
          return true;
      }
    }).toList();
  }

  void _sortBy(String field) {
    setState(() {
      if (_sortField == field) {
        _sortAsc = !_sortAsc;
      } else {
        _sortField = field;
        _sortAsc = true;
      }
      _items = _sortItems(_items);
    });
    _persistPrefs();
  }

  void _toggleSelect(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
        if (_selected.isEmpty) _selectionMode = false;
      } else {
        _selected.add(id);
        _selectionMode = true;
      }
    });
  }

  Future<void> _bulkDelete() async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Move ${ids.length} item(s) to trash?'),
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
      final svc = ref.read(fileServiceProvider);
      for (final id in ids) {
        await svc.deleteFile(id);
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Bulk delete failed: $e')));
      }
    }
  }

  void _showItemMenu(VaultFile file) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (file.isFolder)
              ListTile(
                leading: const Icon(Icons.folder_open_rounded),
                title: const Text('Open'),
                onTap: () {
                  Navigator.pop(ctx);
                  _navigateToFolder(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(file);
              },
            ),
            ListTile(
              leading: Icon(
                file.isFavorite
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                color: file.isFavorite
                    ? const Color(0xFFFB8C00)
                    : null,
              ),
              title: Text(file.isFavorite ? 'Unstar' : 'Star'),
              onTap: () {
                Navigator.pop(ctx);
                _toggleFavorite(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.tag_rounded),
              title: const Text('Tags'),
              subtitle: file.tags.isEmpty
                  ? null
                  : Text(file.tags.map((t) => '#$t').join(' ')),
              onTap: () {
                Navigator.pop(ctx);
                _editTags(file);
              },
            ),
            if (!file.isFolder)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(file);
                },
              ),
            if (file.isFolder)
              ListTile(
                leading: const Icon(Icons.archive_rounded),
                title: const Text('Download as ZIP'),
                onTap: () {
                  Navigator.pop(ctx);
                  _downloadFolder(file);
                },
              ),
            if (!file.isFolder)
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('Share link'),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareFile(file);
                },
              ),
            if (file.isFolder)
              ListTile(
                leading: const Icon(Icons.markunread_mailbox_rounded),
                title: const Text('Request files'),
                subtitle:
                    const Text('Link that lets anyone upload here'),
                onTap: () {
                  Navigator.pop(ctx);
                  _requestFiles(file);
                },
              ),
            if (!file.isFolder)
              Consumer(builder: (context, ref, _) {
                final pinned =
                    ref.watch(offlineServiceProvider).isPinned(file.id);
                return ListTile(
                  leading: Icon(pinned
                      ? Icons.cloud_off_rounded
                      : Icons.cloud_download_rounded),
                  title: Text(pinned
                      ? 'Remove offline copy'
                      : 'Save offline'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleOffline(file, pinned);
                  },
                );
              }),
            ListTile(
              leading: const Icon(Icons.drive_file_move_rounded),
              title: const Text('Move'),
              onTap: () {
                Navigator.pop(ctx);
                _move(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_rounded, color: Colors.red),
              title:
                  const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(file);
              },
            ),
          ],
        ),
      ),
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
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Rename'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == file.name) return;
    try {
      await ref.read(fileServiceProvider).renameFile(file.id, name);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Rename failed: $e')));
      }
    }
  }

  Future<void> _shareFile(VaultFile file) async {
    final passwordController = TextEditingController();
    var expiryHours = 24.0;
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialog) => AlertDialog(
          title: Text('Share "${file.name}"'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Anyone with the link can download this file.'),
              const SizedBox(height: 12),
              DropdownButtonFormField<double>(
                initialValue: expiryHours,
                decoration:
                    const InputDecoration(labelText: 'Link expires'),
                items: const [
                  DropdownMenuItem(value: 1.0, child: Text('After 1 hour')),
                  DropdownMenuItem(value: 24.0, child: Text('After 1 day')),
                  DropdownMenuItem(
                      value: 168.0, child: Text('After 7 days')),
                  DropdownMenuItem(
                      value: 720.0, child: Text('After 30 days')),
                ],
                onChanged: (v) =>
                    setDialog(() => expiryHours = v ?? 24.0),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password (optional)',
                  hintText: 'Min 4 characters',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Create link')),
          ],
        ),
      ),
    );
    if (create != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref.read(fileServiceProvider).createShare(
            fileId: file.id,
            expiresInHours: expiryHours,
            password: passwordController.text.trim().isEmpty
                ? null
                : passwordController.text.trim(),
          );
      final base = ref.read(apiClientProvider).serverUrl ?? '';
      final link = '$base/s/${result.token}';
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Share link ready'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(link),
              const SizedBox(height: 8),
              Text(
                'Manage or revoke it any time in Settings → Shared links.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
            FilledButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                Navigator.pop(ctx);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Share failed: $e')));
    }
  }

  Future<void> _editTags(VaultFile file) async {
    final controller =
        TextEditingController(text: file.tags.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tags for "${file.name}"'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'comma, separated, tags',
            helperText: 'letters, digits, spaces, _ and -',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(ctx, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    if (result == null) return;
    final tags = result
        .split(',')
        .map((t) => t.trim().toLowerCase())
        .where((t) => t.isNotEmpty)
        .toList();
    try {
      await ref.read(fileServiceProvider).setTags(file.id, tags);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Tags failed: $e')));
      }
    }
  }

  Future<void> _downloadFolder(VaultFile folder) async {
    final dir = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose where to save the ZIP');
    if (dir == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Archiving "${folder.name}"…')),
    );
    try {
      await ref.read(fileServiceProvider).downloadArchiveToFile(
            folder.id,
            p.join(dir, '${folder.name}.zip'),
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Saved ${folder.name}.zip')),
      );
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Archive failed: $e')));
    }
  }

  Future<void> _requestFiles(VaultFile folder) async {
    final passwordController = TextEditingController();
    const expiryHours = 168.0;
    final create = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Request files for "${folder.name}"'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
                'Anyone with the link can upload files here (7 days, optional password).'),
            const SizedBox(height: 8),
            TextField(
              controller: passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password (optional)',
                hintText: 'Min 4 characters',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create link')),
        ],
      ),
    );
    if (create != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ref.read(fileServiceProvider).createUploadRequest(
                targetFolderId: folder.id,
                expiresInHours: expiryHours,
                password: passwordController.text.trim().isEmpty
                    ? null
                    : passwordController.text.trim(),
              );
      final base = ref.read(apiClientProvider).serverUrl ?? '';
      final link = '$base/s/${result.token}';
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Upload link ready'),
          content: SelectableText(link),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
            FilledButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                Navigator.pop(ctx);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Link copied')),
                );
              },
            ),
          ],
        ),
      );
    } catch (e) {
      messenger
          .showSnackBar(SnackBar(content: Text('Request failed: $e')));
    }
  }

  Future<void> _toggleOffline(VaultFile file, bool pinned) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final offline = ref.read(offlineServiceProvider);
      if (pinned) {
        await offline.unpin(file.id);
        messenger.showSnackBar(
            const SnackBar(content: Text('Offline copy removed.')));
      } else {
        messenger.showSnackBar(
            SnackBar(content: Text('Saving "${file.name}" offline…')));
        await offline.pin(file);
        messenger.showSnackBar(
            const SnackBar(content: Text('Available offline.')));
      }
      setState(() {});
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Offline failed: $e')));
    }
  }

  Future<void> _newNote() async {
    final titleController = TextEditingController();
    final bodyController = TextEditingController();
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New note'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              autofocus: true,
              decoration:
                  const InputDecoration(labelText: 'Title'),
            ),
            TextField(
              controller: bodyController,
              decoration:
                  const InputDecoration(labelText: 'Text'),
              maxLines: 6,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Upload note')),
        ],
      ),
    );
    if (save != true || !mounted) return;
    final title = titleController.text.trim().isEmpty
        ? 'note'
        : titleController.text.trim();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final notesDir = Directory(p.join(docs.path, 'notes'));
      await notesDir.create(recursive: true);
      final safe =
          title.replaceAll(RegExp(r'[^\w.\- ]'), '_');
      final path = p.join(
          notesDir.path, '$safe-${DateTime.now().millisecondsSinceEpoch}.txt');
      await File(path).writeAsString(bodyController.text);
      if (!mounted) return;
      ref.read(transferManagerProvider).enqueueUpload(
            sourcePath: path,
            parentId: ref.read(currentFolderProvider),
            name: p.basename(path),
          );
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Note queued — see Transfers')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Note failed: $e')));
    }
  }

  Future<void> _toggleFavorite(VaultFile file) async {    try {
      await ref.read(fileServiceProvider).setFavorite(file.id, !file.isFavorite);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Star failed: $e')));
      }
    }
  }

  Future<void> _move(VaultFile file) async {
    final folderId = await showDialog<String>(
      context: context,
      builder: (ctx) => _FolderPickerDialog(
        currentFolder: ref.read(currentFolderProvider),
      ),
    );
    if (folderId == null) return;
    try {
      await ref.read(fileServiceProvider).moveFile(file.id, folderId);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Move failed: $e')));
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
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(fileServiceProvider).deleteFile(file.id);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _download(VaultFile file) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    if (!mounted) return;
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
  }

  Future<void> _upload() async {
    final result = await FilePicker.pickFiles();
    if (result.isEmpty) return;
    if (!mounted) return;
    final existing = {
      for (final f in _items)
        if (!f.isFolder) f.name.toLowerCase(): f,
    };
    final fresh = <({String path, String name})>[];
    final conflicts = <({String path, String name, VaultFile target})>[];
    for (final f in result) {
      final path = f.path;
      if (path == null) continue;
      final hit = existing[f.name.toLowerCase()];
      if (hit != null) {
        conflicts.add((path: path, name: f.name, target: hit));
      } else {
        fresh.add((path: path, name: f.name));
      }
    }
    var replaceAll = false;
    if (conflicts.isNotEmpty) {
      if (!mounted) return;
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('${conflicts.length} file(s) already exist'),
          content: Text(
              '${conflicts.map((c) => c.name).take(3).join(', ')}${conflicts.length > 3 ? '…' : ''}\n\nReplace archives the current content as a version. Keep both uploads a copy.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'cancel'),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'keep'),
              child: const Text('Keep both'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (choice == null || choice == 'cancel') {
        // Upload only the non-conflicting files.
        for (final f in fresh) {
          ref.read(transferManagerProvider).enqueueUpload(
                sourcePath: f.path,
                parentId: ref.read(currentFolderProvider),
                name: f.name,
              );
        }
        return;
      }
      replaceAll = choice == 'replace';
    }
    if (!mounted) return;
    for (final f in fresh) {
      ref.read(transferManagerProvider).enqueueUpload(
            sourcePath: f.path,
            parentId: ref.read(currentFolderProvider),
            name: f.name,
          );
    }
    for (final c in conflicts) {
      if (replaceAll) {
        ref.read(transferManagerProvider).enqueueUpload(
              sourcePath: c.path,
              parentId: ref.read(currentFolderProvider),
              name: c.name,
              replaceFileId: c.target.id,
            );
      } else {
        ref.read(transferManagerProvider).enqueueUpload(
              sourcePath: c.path,
              parentId: ref.read(currentFolderProvider),
              name: c.name,
            );
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Uploads queued — see Transfers')),
      );
    }
  }

  Future<void> _createFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref
          .read(fileServiceProvider)
          .createFolder(ref.read(currentFolderProvider), name);
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Create failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    final offlineIds = ref
        .watch(offlineServiceProvider)
        .entries
        .map((e) => e.id)
        .toSet();
    // Desktop shortcuts: Ctrl+R refresh, Ctrl+Shift+N folder, / search.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyR, control: true):
            () => _load(),
        const SingleActivator(LogicalKeyboardKey.keyN,
            control: true, shift: true): () => _createFolder(),
        const SingleActivator(LogicalKeyboardKey.slash): () =>
            _searchFocus.requestFocus(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
      appBar: AppBar(
        title: _selectionMode
            ? Text('${_selected.length} selected')
            : const Text('Files'),
        leading: _selectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selected.clear();
                  _selectionMode = false;
                }),
              )
            : (_crumbs.length > 1
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => _navigateToCrumb(_crumbs.length - 2),
                  )
                : null),
        actions: [
          if (_selectionMode)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Move to trash',
              onPressed: _bulkDelete,
            )
          else ...[
            IconButton(
              icon: Icon(_isGridView ? Icons.list_rounded : Icons.grid_view_rounded),
              tooltip: 'Toggle view',
              onPressed: () {
                setState(() => _isGridView = !_isGridView);
                _persistPrefs();
              },
            ),
            PopupMenuButton<String>(
              onSelected: _sortBy,
              icon: const Icon(Icons.sort_rounded),
              tooltip: 'Sort ($_sortField)',
              itemBuilder: (_) => [
                PopupMenuItem(
                    value: 'name',
                    child: Text(
                        'Sort by Name ${_sortField == 'name' ? (_sortAsc ? '↑' : '↓') : ''}')),
                PopupMenuItem(
                    value: 'size',
                    child: Text(
                        'Sort by Size ${_sortField == 'size' ? (_sortAsc ? '↑' : '↓') : ''}')),
                PopupMenuItem(
                    value: 'date',
                    child: Text(
                        'Sort by Date ${_sortField == 'date' ? (_sortAsc ? '↑' : '↓') : ''}')),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showFabActions,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
      body: DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (details) async {
          setState(() => _dragging = false);
          for (final f in details.files) {
            ref.read(transferManagerProvider).enqueueUpload(
                  sourcePath: f.path,
                  parentId: ref.read(currentFolderProvider),
                  name: f.name,
                );
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Uploads queued — see Transfers')),
            );
          }
        },
        child: Stack(
          children: [
            Column(
              children: [
                _buildCrumbs(),
                _buildSearchBar(),
                _buildFilterChips(),
                Expanded(child: _buildBody(visible, offlineIds)),
              ],
            ),
            if (_dragging)
              Container(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.85),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_upload_rounded,
                        size: 64,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(height: 16),
                    Text('Drop files here to upload',
                        style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
          ],
        ),
      ),
        ),
      ),
    );
  }

  Widget _buildCrumbs() => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            for (var i = 0; i < _crumbs.length; i++) ...[
              if (i > 0)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 2),
                  child: Icon(Icons.chevron_right_rounded, size: 16),
                ),
              ActionChip(
                label: Text(_crumbs[i].name),
                onPressed:
                    i == _crumbs.length - 1 ? null : () => _navigateToCrumb(i),
              ),
            ],
            const SizedBox(width: 8),
            _SyncPill(syncedAt: _syncedAt),
          ],
        ),
      );

  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SearchBar(
          controller: _searchController,
          focusNode: _searchFocus,
          hintText: 'Search this folder or the vault…  ( / )',
          leading: const Icon(Icons.search_rounded),
          trailing: _query.isEmpty && !_searching
              ? null
              : [
                  if (_searching)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 16,
                          height: 16,
                          child:
                              CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.clear_rounded),
                      onPressed: () {
                        _searchController.clear();
                        _onQueryChanged('');
                      },
                    )
                ],
          onChanged: _onQueryChanged,
        ),
      );

  Widget _buildFilterChips() {
    final offline = ref.watch(offlineServiceProvider);
    void pickFilter(String f) {
      setState(() => _typeFilter = f);
      // Offline list is local; everything else reloads from the host.
      if (f != 'offline') _load();
      if (f == 'offline') {
        setState(() => _items = offline.asVaultFiles());
      }
    }

    Future<void> pickTag() async {
      if (_typeFilter.startsWith('tag:')) {
        pickFilter('all');
        return;
      }
      try {
        final tags = await ref.read(fileServiceProvider).listTags();
        if (!mounted) return;
        if (tags.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('No tags yet — long-press a file → Tags.')),
          );
          return;
        }
        final selected = await showDialog<String>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Filter by tag'),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: tags.length,
                itemBuilder: (_, i) => ListTile(
                  leading: const Icon(Icons.tag_rounded),
                  title: Text(tags[i].tag),
                  trailing: Text('${tags[i].count}'),
                  onTap: () => Navigator.pop(ctx, tags[i].tag),
                ),
              ),
            ),
          ),
        );
        if (selected != null && mounted) pickFilter('tag:$selected');
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Tags failed: $e')));
      }
    }

    final activeTag =
        _typeFilter.startsWith('tag:') ? _typeFilter.substring(4) : null;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              avatar: const Icon(Icons.tag_rounded, size: 18),
              label: Text(activeTag == null ? 'Tags' : '#$activeTag'),
              selected: activeTag != null,
              onSelected: (_) => pickTag(),
            ),
          ),
          for (final f in const [
            ('all', 'All'),
            ('starred', 'Starred'),
            ('recent', 'Recent'),
            ('offline', 'Offline'),
            ('folders', 'Folders'),
            ('images', 'Images'),
            ('docs', 'Docs'),
            ('video', 'Video'),
          ])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(f.$2),
                selected: _typeFilter == f.$1,
                onSelected: (_) => pickFilter(f.$1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(List<VaultFile> visible, Set<String> offlineIds) {
    // Vault-wide server results take over while searching.
    final searching = _query.trim().length >= 2;
    if (searching && _serverResults != null) {
      final results = _serverResults!;
      if (results.isEmpty) {
        return EmptyState(
          icon: Icons.search_off_rounded,
          title: 'No matches in vault',
          subtitle: 'Try a different search.',
          action: OutlinedButton(
            onPressed: () {
              _searchController.clear();
              _onQueryChanged('');
            },
            child: const Text('Clear search'),
          ),
        );
      }
      return Column(
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.travel_explore_rounded,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                Text('Across vault (${results.length})',
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          Expanded(child: _buildList(results, offlineIds)),
        ],
      );
    }
    if (_loading) return const SkeletonList();
    if (_error != null) return ErrorState(message: _error!, onRetry: _load);
    if (_items.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No files yet',
        subtitle: 'Tap New to upload files or create folders.\nTip: drag & drop works on desktop.',
      );
    }
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches',
        subtitle: 'Try a different search or filter.',
        action: OutlinedButton(
          onPressed: () {
            _searchController.clear();
            setState(() {
              _query = '';
              _typeFilter = 'all';
            });
          },
          child: const Text('Clear filters'),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: _isGridView
          ? _buildGrid(visible, offlineIds)
          : _buildList(visible, offlineIds),
    );
  }

  String _subtitle(VaultFile f, bool pinned) {
    final parts = <String>[];
    if (f.isFolder) {
      parts.add(formatDateTime(f.modifiedAt));
    } else {
      parts.add('${formatBytes(f.size)} • ${formatDateTime(f.modifiedAt)}');
    }
    if (f.tags.isNotEmpty) {
      parts.add(f.tags.map((t) => '#$t').join(' '));
    }
    if (pinned) parts.add('offline');
    return parts.join(' • ');
  }

  Widget _buildList(List<VaultFile> visible, Set<String> offlineIds) =>
      ListView.builder(
        itemCount: visible.length,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemBuilder: (context, i) {
          final file = visible[i];
          final selected = _selected.contains(file.id);
          final pinned = offlineIds.contains(file.id);
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: ListTile(
              leading: VaultFileIcon(name: file.name, isFolder: file.isFolder),
              title: Row(
                children: [
                  Expanded(
                    child: Text(file.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (pinned)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(Icons.cloud_off_rounded,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                    ),
                ],
              ),
              subtitle: Text(_subtitle(file, pinned)),
              selected: selected,
              selectedTileColor: Theme.of(context)
                  .colorScheme
                  .primaryContainer
                  .withValues(alpha: 0.4),
              onTap: () {
                if (_selectionMode) {
                  _toggleSelect(file.id);
                } else if (file.isFolder) {
                  _navigateToFolder(file);
                } else {
                  context.push('/client/preview/${file.id}');
                }
              },
              onLongPress: () {
                if (_selectionMode) {
                  _toggleSelect(file.id);
                } else {
                  _showItemMenu(file);
                }
              },
              trailing: _selectionMode
                  ? Checkbox(
                      value: selected,
                      onChanged: (_) => _toggleSelect(file.id),
                    )
                  : IconButton(
                      icon: const Icon(Icons.more_vert_rounded),
                      onPressed: () => _showItemMenu(file),
                    ),
            ),
          );
        },
      );

  Widget _buildGrid(List<VaultFile> visible, Set<String> offlineIds) =>
      LayoutBuilder(builder: (context, constraints) {
        final w = constraints.maxWidth;
        final cols = w > 1100
            ? 6
            : w > 800
                ? 5
                : w > 600
                    ? 4
                    : w > 380
                        ? 3
                        : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.92,
          ),
          itemCount: visible.length,
          itemBuilder: (context, i) {
            final file = visible[i];
            final selected = _selected.contains(file.id);
            return Card(
              color: selected
                  ? Theme.of(context)
                      .colorScheme
                      .primaryContainer
                      .withValues(alpha: 0.5)
                  : null,
              child: InkWell(
                onTap: () {
                  if (_selectionMode) {
                    _toggleSelect(file.id);
                  } else if (file.isFolder) {
                    _navigateToFolder(file);
                  } else {
                    context.push('/client/preview/${file.id}');
                  }
                },
                onLongPress: () => _selectionMode
                    ? _toggleSelect(file.id)
                    : _showItemMenu(file),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (file.hasThumb && !file.isFolder)
                        _GridThumb(fileId: file.id)
                      else
                        VaultFileIcon(
                            name: file.name,
                            isFolder: file.isFolder,
                            size: 52),
                      const SizedBox(height: 10),
                      Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _subtitle(file, offlineIds.contains(file.id)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      });

  void _showFabActions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_rounded),
              title: const Text('Upload Files'),
              subtitle: const Text('Pick one or more files'),
              onTap: () {
                Navigator.pop(ctx);
                _upload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.note_add_rounded),
              title: const Text('New Note'),
              subtitle: const Text('Write text straight to the cloud'),
              onTap: () {
                Navigator.pop(ctx);
                _newNote();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_rounded),
              title: const Text('New Folder'),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderPickerDialog extends ConsumerStatefulWidget {
  final String currentFolder;
  const _FolderPickerDialog({required this.currentFolder});

  @override
  ConsumerState<_FolderPickerDialog> createState() =>
      _FolderPickerDialogState();
}

class _FolderPickerDialogState extends ConsumerState<_FolderPickerDialog> {
  late String _selectedFolder;
  List<VaultFile> _folders = [];
  final List<String> _path = ['root'];

  @override
  void initState() {
    super.initState();
    _selectedFolder = widget.currentFolder;
    _loadFolders('root');
  }

  Future<void> _loadFolders(String parentId) async {
    try {
      final items = await ref.read(fileServiceProvider).listFiles(parentId);
      if (!mounted) return;
      setState(() {
        _folders = items.where((f) => f.isFolder).toList();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _folders = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Move to...'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              children: [
                for (var i = 0; i < _path.length; i++)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _path.removeRange(i + 1, _path.length);
                        _loadFolders(_path.last);
                      });
                    },
                    child: Text(i == 0 ? 'Root' : _path[i]),
                  ),
              ],
            ),
            const Divider(),
            Flexible(
              child: _folders.isEmpty
                  ? const Text('No sub-folders')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _folders.length,
                      itemBuilder: (_, i) {
                        final f = _folders[i];
                        return ListTile(
                          leading: VaultFileIcon(name: f.name, isFolder: true, size: 36),
                          title: Text(f.name),
                          selected: _selectedFolder == f.id,
                          onTap: () {
                            setState(() {
                              _selectedFolder = f.id;
                              _path.add(f.name);
                            });
                            _loadFolders(f.id);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedFolder),
          child: const Text('Move Here'),
        ),
      ],
    );
  }
}
