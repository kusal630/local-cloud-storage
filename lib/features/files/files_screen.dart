import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/widgets/common.dart';

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});
  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  bool _isGridView = false;
  bool _loading = false;
  List<VaultFile> _items = [];
  String? _error;
  String _sortField = 'name';
  bool _sortAsc = true;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
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
      setState(() {
        _items = _sortItems(items);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
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
                leading: const Icon(Icons.folder_open),
                title: const Text('Open'),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(currentFolderProvider.notifier).state = file.id;
                  _load();
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Rename'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(file);
              },
            ),
            if (!file.isFolder)
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(file);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_move),
              title: const Text('Move'),
              onTap: () {
                Navigator.pop(ctx);
                _move(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
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
        const SnackBar(content: Text('Uploads queued')),
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          IconButton(
            icon: Icon(_isGridView ? Icons.list : Icons.grid_view),
            onPressed: () => setState(() => _isGridView = !_isGridView),
          ),
          PopupMenuButton<String>(
            onSelected: _sortBy,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'name', child: Text('Sort by Name')),
              const PopupMenuItem(value: 'size', child: Text('Sort by Size')),
              const PopupMenuItem(value: 'date', child: Text('Sort by Date')),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: _showSearch,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showFabActions,
        child: const Icon(Icons.add),
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
        },
        child: Stack(
          children: [
            if (_loading)
              const LoadingIndicator()
            else if (_error != null)
              ErrorState(message: _error!, onRetry: _load)
            else if (_items.isEmpty)
              const EmptyState(
                icon: Icons.folder_open,
                title: 'No files yet',
                subtitle: 'Tap + to upload files or create folders',
              )
            else
              RefreshIndicator(
                onRefresh: _load,
                child: _isGridView ? _buildGrid(context) : _buildList(context),
              ),
            if (_dragging)
              Container(
                color: Theme.of(context)
                    .colorScheme
                    .primaryContainer
                    .withValues(alpha: 0.8),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.cloud_upload,
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

  void _showFabActions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload File'),
              onTap: () {
                Navigator.pop(ctx);
                _upload();
              },
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder),
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

  void _showSearch() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Search Files'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Search...'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final query = controller.text.trim();
              if (query.isEmpty) return;
              final messenger = ScaffoldMessenger.of(context);
              try {
                final results =
                    await ref.read(fileServiceProvider).search(query);
                if (context.mounted) {
                  _showSearchResults(results);
                }
              } catch (e) {
                if (context.mounted) {
                  messenger
                      .showSnackBar(SnackBar(content: Text('Search failed: $e')));
                }
              }
            },
            child: const Text('Search'),
          ),
        ],
      ),
    );
  }

  void _showSearchResults(List<VaultFile> results) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Results (${results.length})'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: results.length,
            itemBuilder: (_, i) {
              final file = results[i];
              return ListTile(
                leading: Icon(
                    file.isFolder ? Icons.folder : Icons.insert_drive_file),
                title: Text(file.name),
                subtitle: file.isFolder ? null : Text(formatBytes(file.size)),
                onTap: () {
                  Navigator.pop(ctx);
                  if (file.isFolder) {
                    ref.read(currentFolderProvider.notifier).state = file.id;
                    _load();
                  } else {
                    context.push('/client/preview/${file.id}');
                  }
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    return ListView.builder(
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final file = _items[i];
        return ListTile(
          leading:
              Icon(file.isFolder ? Icons.folder : Icons.insert_drive_file),
          title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: file.isFolder ? null : Text(formatBytes(file.size)),
          onTap: () {
            if (file.isFolder) {
              ref.read(currentFolderProvider.notifier).state = file.id;
              _load();
            } else {
              context.push('/client/preview/${file.id}');
            }
          },
          onLongPress: () => _showItemMenu(file),
        );
      },
    );
  }

  Widget _buildGrid(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final file = _items[i];
        return Card(
          child: InkWell(
            onTap: () {
              if (file.isFolder) {
                ref.read(currentFolderProvider.notifier).state = file.id;
                _load();
              } else {
                context.push('/client/preview/${file.id}');
              }
            },
            onLongPress: () => _showItemMenu(file),
            borderRadius: BorderRadius.circular(16),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  file.isFolder ? Icons.folder : Icons.insert_drive_file,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    file.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
      setState(() {
        _folders = items.where((f) => f.isFolder).toList();
      });
    } catch (_) {
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
            Expanded(
              child: _folders.isEmpty
                  ? const Text('No sub-folders')
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _folders.length,
                      itemBuilder: (_, i) {
                        final f = _folders[i];
                        return ListTile(
                          leading: const Icon(Icons.folder),
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