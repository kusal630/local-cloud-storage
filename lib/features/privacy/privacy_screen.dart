import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/providers.dart';
import '../../widgets/common.dart';

/// Privacy control center: what lives on this device, and one-tap clearing.
///
/// The app collects nothing itself — no analytics, no trackers, no accounts.
/// Everything below is local convenience data the user fully controls.
class PrivacyScreen extends ConsumerStatefulWidget {
  const PrivacyScreen({super.key});
  @override
  ConsumerState<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends ConsumerState<PrivacyScreen> {
  int _searchCount = 0;
  bool _searchLoading = true;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _searchLoading = true;
      _searchError = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final count = (prefs.getStringList('search_history') ?? []).length;
      if (!mounted) return;
      setState(() {
        _searchCount = count;
        _searchLoading = false;
        _searchError = null;
      });
    } catch (_) {
      // "0 recent queries" would be a lie when the real answer is
      // "couldn't load" — say so and offer a retry.
      if (!mounted) return;
      setState(() {
        _searchLoading = false;
        _searchError = 'Could not load search history.';
      });
    }
  }

  Future<void> _clearSearch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('search_history');
      _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Search history cleared.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not clear search history.')),
      );
    }
  }

  Future<void> _clearOffline() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete all offline copies?'),
        content: const Text(
            'Files stay safe in your cloud — only local copies are removed.'),
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
    await ref.read(offlineServiceProvider).clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Offline copies deleted.')),
    );
  }

  Future<void> _clearTransfers() async {
    ref.read(transferManagerProvider).clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Transfer history cleared.')),
    );
  }

  String _searchSubtitle() {
    if (_searchLoading) return 'Loading…';
    if (_searchError != null) return _searchError!;
    final count = _searchCount;
    final noun =
        Intl.pluralLogic(count, one: 'query', other: 'queries');
    return '$count recent $noun on this device';
  }

  @override
  Widget build(BuildContext context) {
    final offline = ref.watch(offlineServiceProvider);
    final transfers = ref.watch(transferManagerProvider).tasks.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SectionHeader(title: 'OUR PROMISE'),
                  const Text(
                    'LocalVault has no analytics, no trackers, no accounts, '
                    'and no servers of its own. Your files move only between '
                    'your devices over pinned TLS. What remains on this phone '
                    'is listed below — delete any of it any time.',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_off_rounded),
                  title: const Text('Offline copies'),
                  subtitle: Text(
                      '${offline.entries.length} files • ${formatBytes(offline.totalBytes)}'),
                  trailing: TextButton(
                    onPressed:
                        offline.entries.isEmpty ? null : _clearOffline,
                    child: const Text('Delete all'),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.history_rounded),
                  title: const Text('Search history'),
                  subtitle: Text(_searchSubtitle()),
                  trailing: _searchError != null
                      ? TextButton(
                          onPressed: _load, child: const Text('Retry'))
                      : TextButton(
                          onPressed: (_searchLoading || _searchCount == 0)
                              ? null
                              : _clearSearch,
                          child: const Text('Clear')),
                ),
                const Divider(height: 1),
                ListTile(
                  leading:
                      const Icon(Icons.swap_vert_circle_rounded),
                  title: const Text('Transfer history'),
                  subtitle: Text(
                      '$transfers ${Intl.pluralLogic(transfers, one: 'entry', other: 'entries')} on this device'),
                  trailing: TextButton(
                    onPressed:
                        transfers == 0 ? null : _clearTransfers,
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
