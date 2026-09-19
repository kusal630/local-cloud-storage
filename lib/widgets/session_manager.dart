import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';

/// Active session information.
class SessionInfo {
  const SessionInfo({
    required this.id,
    required this.deviceName,
    required this.lastActive,
    required this.createdAt,
    this.ipAddress,
    this.isCurrent = false,
    this.userAgent,
  });

  final String id;
  final String deviceName;
  final DateTime lastActive;
  final DateTime createdAt;
  final String? ipAddress;
  final bool isCurrent;
  final String? userAgent;

  String get deviceType {
    if (userAgent == null) return 'Unknown';
    final ua = userAgent!.toLowerCase();
    if (ua.contains('android')) return 'Android';
    if (ua.contains('iphone') || ua.contains('ipad')) return 'iOS';
    if (ua.contains('windows')) return 'Windows';
    if (ua.contains('linux')) return 'Linux';
    if (ua.contains('mac')) return 'macOS';
    return 'Web';
  }

  IconData get deviceIcon {
    switch (deviceType) {
      case 'Android':
        return Icons.android_rounded;
      case 'iOS':
        return Icons.phone_iphone_rounded;
      case 'Windows':
        return Icons.desktop_windows_rounded;
      case 'Linux':
        return Icons.computer_rounded;
      case 'macOS':
        return Icons.laptop_mac_rounded;
      default:
        return Icons.device_unknown_rounded;
    }
  }
}

/// Session manager widget showing all active sessions.
class SessionManager extends StatelessWidget {
  const SessionManager({
    super.key,
    required this.sessions,
    required this.onRevoke,
    required this.onRevokeAll,
  });

  final List<SessionInfo> sessions;
  final ValueChanged<String> onRevoke;
  final VoidCallback onRevokeAll;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            children: [
              Icon(Icons.shield_rounded, color: scheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                'Active Sessions',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              if (sessions.length > 1)
                TextButton(
                  onPressed: () {
                    AppHaptics.heavy();
                    _showRevokeAllDialog(context);
                  },
                  child: Text(
                    'Revoke all others',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ),
        // Session list
        Expanded(
          child: sessions.isEmpty
              ? const Center(
                  child: Text('No active sessions'),
                )
              : ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return _SessionTile(
                      session: session,
                      onRevoke: onRevoke,
                    );
                  },
                ),
        ),
        // Security info
        Padding(
          padding: const EdgeInsets.all(16),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 16, color: scheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sessions expire after 30 days of inactivity. '
                    'Revoking a session signs out that device immediately.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showRevokeAllDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke all other sessions?'),
        content: const Text(
          'This will sign out all other devices. You will need to log in again on each device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              AppHaptics.heavy();
              Navigator.pop(ctx);
              onRevokeAll();
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Revoke all'),
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.onRevoke,
  });

  final SessionInfo session;
  final ValueChanged<String> onRevoke;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: session.isCurrent
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            session.deviceIcon,
            color: session.isCurrent
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
            size: 24,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                session.deviceName,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (session.isCurrent)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'This device',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '${session.deviceType}${session.ipAddress != null ? ' • ${session.ipAddress}' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 2),
            Text(
              'Last active: ${_formatRelative(session.lastActive)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.outline,
                  ),
            ),
          ],
        ),
        trailing: session.isCurrent
            ? null
            : PopupMenuButton(
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'revoke',
                    child: Text('Revoke',
                        style: TextStyle(color: Colors.red)),
                  ),
                ],
                onSelected: (value) {
                  if (value == 'revoke') {
                    AppHaptics.heavy();
                    onRevoke(session.id);
                  }
                },
              ),
      ),
    );
  }

  String _formatRelative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
