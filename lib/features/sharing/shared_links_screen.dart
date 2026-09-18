import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../data/models/shared_link.dart';
import '../../widgets/common.dart';

/// Lists active share links with revoke + copy. Reached from Settings.
class SharedLinksScreen extends ConsumerStatefulWidget {
  const SharedLinksScreen({super.key});
  @override
  ConsumerState<SharedLinksScreen> createState() => _SharedLinksScreenState();
}

class _SharedLinksScreenState extends ConsumerState<SharedLinksScreen> {
  List<SharedLink>? _links;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final links = await ref.read(fileServiceProvider).listShares();
      if (!mounted) return;
      setState(() {
        _links = links;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _revoke(SharedLink link) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke link?'),
        content: Text(
            'The link for "${link.fileName}" stops working immediately.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Revoke')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(fileServiceProvider).deleteShare(link.tokenPrefix);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Revoke failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shared links')),
      body: _error != null
          ? ErrorState(message: _error!, onRetry: _load)
          : _links == null
              ? const SkeletonList()
              : _links!.isEmpty
                  ? EmptyState(
                      icon: Icons.link_rounded,
                      title: 'No share links',
                      subtitle:
                          'Long-press any file → Share link to create one.',
                      action: FilledButton(
                        onPressed: () => context.pop(),
                        child: const Text('Browse files'),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: _links!.length,
                        itemBuilder: (_, i) {
                          final link = _links![i];
                          final base =
                              ref.read(apiClientProvider).serverUrl ?? '';
                          final url = '$base/s/…${link.tokenPrefix}';
                          return Card(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            child: ListTile(
                              leading: VaultFileIcon(
                                  name: link.fileName, size: 40),
                              title: Text(link.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                  '${link.downloadCount} downloads'
                                  '${link.hasPassword ? ' • locked' : ''}'
                                  '${link.expiresAt == null ? ' • never expires' : ' • expires ${formatDateTime(link.expiresAt!)}'}\n$url'),
                              isThreeLine: true,
                              trailing: IconButton(
                                icon: const Icon(Icons.link_off_rounded),
                                tooltip: 'Revoke',
                                onPressed: () => _revoke(link),
                              ),
                              onTap: () {
                                Clipboard.setData(
                                    ClipboardData(text: url));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          'Prefix copied (full link was shown at creation)')),
                                );
                              },
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}
