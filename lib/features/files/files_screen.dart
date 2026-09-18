import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
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

  @override
  void initState() {
    super.initState();
    _restorePrefs();
    _load();
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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folder = ref.read(currentFolderProvider);
      final svc = ref.read(fileServiceProvider);
      final items = await svc.listFiles(folder);
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

  List<VaultFile> get _visible {
    final q = _query.trim().toLowerCase();
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
            if (!file.isFolder)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(file);
                },
              ),
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
    for (final f in result) {
      final path = f.path;
      if (path == null) continue;
      ref.read(transferManagerProvider).enqueueUpload(
            sourcePath: path,
            parentId: ref.read(currentFolderProvider),
            name: f.name,
          );
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
    return Scaffold(
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
                Expanded(child: _buildBody(visible)),
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
          ],
        ),
      );

  Widget _buildSearchBar() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SearchBar(
          controller: _searchController,
          hintText: 'Search in this folder…',
          leading: const Icon(Icons.search_rounded),
          trailing: _query.isEmpty
              ? null
              : [
                  IconButton(
                    icon: const Icon(Icons.clear_rounded),
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _query = '');
                    },
                  )
                ],
          onChanged: (v) => setState(() => _query = v),
        ),
      );

  Widget _buildFilterChips() {
    const filters = [
      ('all', 'All'),
      ('folders', 'Folders'),
      ('images', 'Images'),
      ('docs', 'Docs'),
      ('video', 'Video'),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final f in filters)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(f.$2),
                selected: _typeFilter == f.$1,
                onSelected: (_) => setState(() => _typeFilter = f.$1),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(List<VaultFile> visible) {
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
      child: _isGridView ? _buildGrid(visible) : _buildList(visible),
    );
  }

  String _subtitle(VaultFile f) {
    if (f.isFolder) return formatDateTime(f.modifiedAt);
    return '${formatBytes(f.size)} • ${formatDateTime(f.modifiedAt)}';
  }

  Widget _buildList(List<VaultFile> visible) => ListView.builder(
        itemCount: visible.length,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemBuilder: (context, i) {
          final file = visible[i];
          final selected = _selected.contains(file.id);
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: ListTile(
              leading: VaultFileIcon(name: file.name, isFolder: file.isFolder),
              title: Text(file.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_subtitle(file)),
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

  Widget _buildGrid(List<VaultFile> visible) =>
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
                      VaultFileIcon(
                          name: file.name, isFolder: file.isFolder, size: 52),
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
                        _subtitle(file),
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
