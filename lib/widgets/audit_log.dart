import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';
import 'common.dart';

/// Audit log entry for security tracking.
class AuditEntry {
  const AuditEntry({
    required this.timestamp,
    required this.action,
    required this.details,
    this.deviceName,
    this.ipAddress,
    this.success = true,
  });

  final DateTime timestamp;
  final String action;
  final String details;
  final String? deviceName;
  final String? ipAddress;
  final bool success;

  IconData get icon {
    switch (action.toLowerCase()) {
      case 'login':
        return Icons.login_rounded;
      case 'logout':
        return Icons.logout_rounded;
      case 'upload':
        return Icons.cloud_upload_rounded;
      case 'download':
        return Icons.cloud_download_rounded;
      case 'delete':
        return Icons.delete_rounded;
      case 'share':
        return Icons.share_rounded;
      case 'pair':
        return Icons.devices_rounded;
      case 'settings':
        return Icons.settings_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Color get color {
    if (!success) return Colors.red;
    switch (action.toLowerCase()) {
      case 'login':
      case 'pair':
        return Colors.green;
      case 'delete':
        return Colors.orange;
      default:
        return Colors.blue;
    }
  }
}

/// Audit log viewer with filtering and search.
class AuditLogViewer extends StatefulWidget {
  const AuditLogViewer({
    super.key,
    required this.entries,
    this.onRefresh,
  });

  final List<AuditEntry> entries;
  final VoidCallback? onRefresh;

  @override
  State<AuditLogViewer> createState() => _AuditLogViewerState();
}

class _AuditLogViewerState extends State<AuditLogViewer> {
  String _filter = 'all';
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.entries.where((e) {
      if (_filter != 'all' && e.action.toLowerCase() != _filter) return false;
      if (_search.isNotEmpty &&
          !e.action.toLowerCase().contains(_search.toLowerCase()) &&
          !e.details.toLowerCase().contains(_search.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    return Column(
      children: [
        // Search bar
        Padding(
          padding: const EdgeInsets.all(16),
          child: SearchBar(
            hintText: 'Search audit log...',
            leading: const Padding(
              padding: EdgeInsets.only(left: 12),
              child: Icon(Icons.search_rounded, size: 20),
            ),
            onChanged: (v) => setState(() => _search = v),
          ),
        ),
        // Filter chips
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _FilterChip(
                label: 'All',
                selected: _filter == 'all',
                onTap: () => setState(() => _filter = 'all'),
              ),
              _FilterChip(
                label: 'Login',
                selected: _filter == 'login',
                onTap: () => setState(() => _filter = 'login'),
              ),
              _FilterChip(
                label: 'Upload',
                selected: _filter == 'upload',
                onTap: () => setState(() => _filter = 'upload'),
              ),
              _FilterChip(
                label: 'Download',
                selected: _filter == 'download',
                onTap: () => setState(() => _filter = 'download'),
              ),
              _FilterChip(
                label: 'Delete',
                selected: _filter == 'delete',
                onTap: () => setState(() => _filter = 'delete'),
              ),
              _FilterChip(
                label: 'Share',
                selected: _filter == 'share',
                onTap: () => setState(() => _filter = 'share'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Log entries
        Expanded(
          child: filtered.isEmpty
              ? const EmptyState(
                  icon: Icons.history_rounded,
                  title: 'No audit entries',
                  subtitle: 'Security events will appear here.',
                )
              : ListView.builder(
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final entry = filtered[index];
                    return _AuditTile(entry: entry);
                  },
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          AppHaptics.selection();
          onTap();
        },
        selectedColor: scheme.primaryContainer,
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: entry.color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(entry.icon, color: entry.color, size: 20),
      ),
      title: Text(
        entry.action,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.details, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                formatRelative(entry.timestamp),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.outline,
                    ),
              ),
              if (entry.deviceName != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.devices_rounded, size: 12, color: scheme.outline),
                const SizedBox(width: 4),
                Text(
                  entry.deviceName!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                ),
              ],
              if (entry.ipAddress != null) ...[
                const SizedBox(width: 8),
                Icon(Icons.wifi_rounded, size: 12, color: scheme.outline),
                const SizedBox(width: 4),
                Text(
                  entry.ipAddress!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                ),
              ],
            ],
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
