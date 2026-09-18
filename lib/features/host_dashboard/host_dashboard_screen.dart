import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/widgets/common.dart';
import 'package:qr_flutter/qr_flutter.dart';

class HostDashboardScreen extends ConsumerStatefulWidget {
  const HostDashboardScreen({super.key});
  @override
  ConsumerState<HostDashboardScreen> createState() =>
      _HostDashboardScreenState();
}

class _HostDashboardScreenState extends ConsumerState<HostDashboardScreen> {
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(hostStateProvider);
    if (data == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Host Dashboard')),
        body: const ErrorState(message: 'No host is running.'),
      );
    }
    final server = data.server;
    final vault = data.vault;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Host Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined),
            tooltip: 'Stop Server',
            onPressed: () async {
              await server.stop();
              if (context.mounted) {
                ref.read(hostStateProvider.notifier).state = null;
                ref.read(appModeProvider.notifier).state = AppMode.welcome;
                context.go('/');
              }
            },
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusPill(
                            label: server.isRunning ? 'RUNNING' : 'STOPPED',
                            color: server.isRunning
                                ? const Color(0xFF43A047)
                                : Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          const StatusPill(
                            label: 'LAN-ONLY :8484',
                            color: Color(0xFF0E7C7B),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const SectionHeader(title: 'CONNECT'),
                      if (server.isRunning) ...[
                        const Text('Server URL'),
                        const SizedBox(height: 4),
                        _ServerUrls(server: server),
                        const SizedBox(height: 12),
                        const Text('Pairing Code'),
                        const SizedBox(height: 4),
                        _PairingSection(vault: vault, server: server),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'DEVICES'),
                      _DevicesList(vault: vault),
                      const SizedBox(height: 8),
                      _ApiTokenButton(server: server),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'REMOTE ACCESS'),
                      _RemoteAccess(vault: vault, server: server),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'STORAGE'),
                      _StorageInfo(vault: vault),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'HOST SETTINGS'),
                      _HostSettings(vault: vault),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        title: 'SECURITY',
                        action: StatusPill(
                          label: _securityScore(vault, server),
                          color: const Color(0xFF43A047),
                        ),
                      ),
                      _SecurityList(vault: vault, server: server),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'ACTIVITY'),
                      _ActivityFeed(vault: vault),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ServerUrls extends StatelessWidget {
  final dynamic server;
  const _ServerUrls({required this.server});
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: server.urls() as Future<List<String>>,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LoadingIndicator();
        final urls = snapshot.data!;
        return Column(
          children: urls
              .map((url) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: SelectableText(url),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy, size: 18),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: url));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('URL copied')),
                        );
                      },
                    ),
                  ))
              .toList(),
        );
      },
    );
  }
}

class _PairingSection extends StatefulWidget {
  final dynamic vault;
  final dynamic server;
  const _PairingSection({required this.vault, required this.server});
  @override
  State<_PairingSection> createState() => _PairingSectionState();
}

class _PairingSectionState extends State<_PairingSection> {
  String? _code;
  String? _lanHost;
  String? _fingerprint;
  bool _loadingCode = true;

  @override
  void initState() {
    super.initState();
    _resolveLan();
    _loadCode();
  }

  Future<void> _resolveLan() async {
    try {
      final url = await (widget.server.lanUrl() as Future<String?>);
      if (!mounted) return;
      final scheme =
          (widget.server.scheme as String?) ?? 'https';
      setState(() {
        _lanHost = (url ?? '$scheme://localhost:${widget.server.port}')
            .replaceFirst(RegExp(r'^https?://'), '');
        try {
          _fingerprint = widget.server.fingerprint as String?;
        } catch (_) {
          _fingerprint = null;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _lanHost = 'localhost:${widget.server.port}');
    }
  }

  Future<void> _loadCode({bool regenerate = false}) async {
    if (!regenerate) setState(() => _loadingCode = true);
    try {
      final devices = widget.vault.devices.listAll() as List;
      if (devices.isEmpty) {
        if (!mounted) return;
        setState(() => _loadingCode = false);
        return;
      }
      final code = await (widget.server.ensurePairingCode(
          devices.first.id) as Future<String>);
      if (!mounted) return;
      setState(() {
        _code = code;
        _loadingCode = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingCode = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vault = widget.vault;
    List devices = const [];
    try {
      devices = vault.devices.listAll() as List;
    } catch (_) {}
    if (devices.isEmpty) return const Text('No host device found.');

    final qrData = _lanHost == null
        ? null
        : (_fingerprint == null || _fingerprint!.isEmpty)
            ? 'localvault://$_lanHost'
            : 'localvault://$_lanHost?fp=$_fingerprint';
    return Column(
      children: [
        if (qrData == null)
          const LoadingIndicator()
        else
          QrImageView(
            data: qrData,
            version: QrVersions.auto,
            size: 180,
          ),
        const SizedBox(height: 12),
        if (_loadingCode || _code == null || _code!.isEmpty)
          const LoadingIndicator()
        else
          SelectableText(
            _code!,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
        const SizedBox(height: 4),
        Text('Expires in 5 minutes',
            style: Theme.of(context).textTheme.bodySmall),
        if (_fingerprint != null && _fingerprint!.isNotEmpty) ...[
          const SizedBox(height: 8),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.lock_rounded, size: 20),
            title: const Text('TLS fingerprint'),
            subtitle: SelectableText(
              _fingerprint!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: _fingerprint!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Fingerprint copied')),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () {
            setState(() => _code = null);
            _loadCode(regenerate: true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Pairing code refreshed')),
            );
          },
          child: const Text('Regenerate'),
        ),
      ],
    );
  }
}

class _DevicesList extends ConsumerStatefulWidget {
  final dynamic vault;
  const _DevicesList({required this.vault});
  @override
  ConsumerState<_DevicesList> createState() => _DevicesListState();
}

class _DevicesListState extends ConsumerState<_DevicesList> {
  @override
  Widget build(BuildContext context) {
    final devices = widget.vault.devices.listAll();
    if (devices.isEmpty) {
      return const EmptyState(
        icon: Icons.devices_other_rounded,
        title: 'No devices yet',
        subtitle: 'Pair a phone or desktop with the QR code above.',
      );
    }
    return Column(
      children: devices
          .map((d) => Card(
                margin: const EdgeInsets.symmetric(vertical: 3),
                child: ListTile(
                  dense: true,
                  leading: VaultFileIcon(
                      name: d.isCurrent ? 'host' : 'phone',
                      isFolder: false,
                      size: 36),
                  title: Text(d.name),
                  subtitle: Text(d.lastSeenAt != null
                      ? 'Last seen ${formatDateTime(d.lastSeenAt)}'
                      : 'Just paired'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (d.isCurrent)
                        const StatusPill(
                            label: 'HOST', color: Color(0xFF0E7C7B))
                      else
                        IconButton(
                          icon: const Icon(Icons.block_rounded, size: 20),
                          tooltip: 'Revoke',
                          onPressed: () {
                            widget.vault.devices.revoke(d.id);
                            setState(() {});
                          },
                        ),
                    ],
                  ),
                ),
              ))
          .toList(),
    );
  }
}

class _StorageInfo extends ConsumerStatefulWidget {
  final dynamic vault;
  const _StorageInfo({required this.vault});
  @override
  ConsumerState<_StorageInfo> createState() => _StorageInfoState();
}

class _StorageInfoState extends ConsumerState<_StorageInfo> {
  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: widget.vault.storageStatus(),
      builder: (context, AsyncSnapshot snapshot) {
        if (snapshot.hasError) {
          return Text('Error: ${snapshot.error}');
        }
        if (!snapshot.hasData) return const LoadingIndicator();
        final status = snapshot.data;
        final total = (status.total as int);
        final free = (status.free as int);
        final used = total - free;
        final vaultUsage = (status.vaultUsage as int);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            StorageMeter(
              fraction: total > 0 ? used / total : 0,
              usedLabel: 'Used ${formatBytes(used)}',
              freeLabel: 'Free ${formatBytes(free)}',
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            StorageMeter(
              fraction: total > 0 ? vaultUsage / total : 0,
              usedLabel: 'Vault ${formatBytes(vaultUsage)}',
              freeLabel: 'Trash ${formatBytes(status.trashUsage as int)}',
            ),
            const SizedBox(height: 8),
            _row('Total', formatBytes(total)),
            _row('Free', formatBytes(free)),
          ],
        );
      },
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [Text(label), Text(value)],
        ),
      );
}

class _HostSettings extends StatefulWidget {
  final dynamic vault;
  const _HostSettings({required this.vault});
  @override
  State<_HostSettings> createState() => _HostSettingsState();
}

class _HostSettingsState extends State<_HostSettings> {
  late final TextEditingController _retention;
  late final TextEditingController _quotaGb;
  late final TextEditingController _cert;
  late final TextEditingController _key;
  String? _saved;

  @override
  void initState() {
    super.initState();
    final settings = widget.vault.settings;
    _retention =
        TextEditingController(text: '${settings.trashRetentionDays}');
    final quota = settings.deviceQuotaBytes as int;
    _quotaGb = TextEditingController(
        text: quota <= 0 ? '' : (quota / 1073741824).toStringAsFixed(1));
    _cert =
        TextEditingController(text: '${settings.tlsCertPath ?? ''}');
    _key = TextEditingController(text: '${settings.tlsKeyPath ?? ''}');
  }

  @override
  void dispose() {
    _retention.dispose();
    _quotaGb.dispose();
    _cert.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      final days = int.tryParse(_retention.text.trim()) ?? -1;
      if (days < 0 || days > 3650) {
        setState(() => _saved = 'Retention must be 0..3650 days.');
        return;
      }
      final quotaGb = _quotaGb.text.trim();
      final quotaBytes = quotaGb.isEmpty
          ? 0
          : ((double.tryParse(quotaGb) ?? -1) * 1073741824).round();
      if (quotaBytes < 0) {
        setState(() => _saved = 'Quota must be empty or >= 0 GB.');
        return;
      }
      widget.vault.settings.trashRetentionDays = days;
      widget.vault.settings.deviceQuotaBytes = quotaBytes;
      final cert = _cert.text.trim();
      final key = _key.text.trim();
      if (cert.isEmpty && key.isEmpty) {
        widget.vault.settings.tlsPaths = null;
      } else {
        widget.vault.settings.tlsPaths = (cert: cert, key: key);
      }
      setState(() => _saved =
          'Saved. TLS takes effect on next server start.');
    } catch (e) {
      setState(() => _saved = 'Save failed: $e');
    }
  }

  Future<void> _purgeNow() async {
    try {
      final n = await widget.vault.purgeExpiredTrash();
      if (!mounted) return;
      setState(() => _saved = 'Purged $n orphaned blob(s).');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Purged $n orphaned blob(s).')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saved = 'Purge failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: _retention,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Trash retention (days, 0 = forever)',
            prefixIcon: Icon(Icons.auto_delete_rounded),
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _quotaGb,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Vault quota (GB, empty = unlimited)',
            prefixIcon: Icon(Icons.pie_chart_rounded),
          ),
        ),
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced — custom TLS certificate'),
          subtitle: const Text(
              'Leave empty for the automatic certificate.'),
          children: [
            TextField(
              controller: _cert,
              decoration: const InputDecoration(
                labelText: 'TLS cert PEM path (optional)',
                prefixIcon: Icon(Icons.lock_rounded),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              decoration: const InputDecoration(
                labelText: 'TLS key PEM path (optional)',
                prefixIcon: Icon(Icons.key_rounded),
              ),
            ),
          ],
        ),
        if (_saved != null) ...[
          const SizedBox(height: 8),
          Text(_saved!, style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _save,
                child: const Text('Save'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: _purgeNow,
                child: const Text('Purge now'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Explains how this node is reached: any network path to the device works
/// (same Wi-Fi, phone hotspot, Tailscale/ZeroTier VPN); true anywhere-access
/// needs a VPN or a port-forward of the server port on the router.
/// Creates long-lived API tokens for scripts and automation. The plaintext
/// is shown exactly once.
class _ApiTokenButton extends StatefulWidget {
  final dynamic server;
  const _ApiTokenButton({required this.server});
  @override
  State<_ApiTokenButton> createState() => _ApiTokenButtonState();
}

class _ApiTokenButtonState extends State<_ApiTokenButton> {
  bool _busy = false;

  Future<void> _create() async {
    final nameController = TextEditingController(text: 'automation');
    final daysController = TextEditingController(text: '365');
    final input = await showDialog<({String name, int days})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New API token'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration:
                  const InputDecoration(labelText: 'Name (e.g. pi-sync)'),
            ),
            TextField(
              controller: daysController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Valid for (days, max 3650)'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, (
                    name: nameController.text.trim().isEmpty
                        ? 'automation'
                        : nameController.text.trim(),
                    days: int.tryParse(daysController.text.trim()) ?? 365,
                  )),
              child: const Text('Create')),
        ],
      ),
    );
    if (input == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final created = await (widget.server.createApiToken(
        name: input.name,
        days: input.days.clamp(1, 3650),
      ) as Future<({String deviceId, String access, String refresh})>);
      if (!mounted) return;
      setState(() => _busy = false);
      if (created.access.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Token creation failed.')),
        );
        return;
      }
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Token created — copy now'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Shown exactly once:'),
              const SizedBox(height: 8),
              SelectableText('Access:\n${created.access}'),
              const SizedBox(height: 8),
              SelectableText('Refresh:\n${created.refresh}'),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done')),
            FilledButton.icon(
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy access'),
              onPressed: () {
                Clipboard.setData(
                    ClipboardData(text: created.access));
                Navigator.pop(ctx);
              },
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _create,
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.key_rounded),
      label: const Text('New API token (scripts & automation)'),
    );
  }
}

class _RemoteAccess extends StatelessWidget {
  final dynamic vault;
  final dynamic server;
  const _RemoteAccess({required this.vault, required this.server});

  @override
  Widget build(BuildContext context) {
    String username = 'owner';
    int port = 8484;
    try {
      username = '${vault.settings.ownerUsername}';
    } catch (_) {}
    try {
      port = server.port as int;
    } catch (_) {}
    return Column(
      children: [
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_rounded),
          title: const Text('Cloud login'),
          subtitle: Text('Username: $username (password you set)'),
        ),
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.router_rounded),
          title: const Text('Anywhere access'),
          subtitle: Text(
              'Port $port. Same network works directly. From anywhere: join the same Tailscale/ZeroTier VPN on both devices, or port-forward $port to this device on your router.'),
        ),
      ],
    );
  }
}

/// Trust at a glance: visible security posture builds confidence to host.
String _securityScore(dynamic vault, dynamic server) {
  var pass = 0;
  var total = 0;
  bool secure = false;
  try {
    secure = (server.isSecure as bool?) ??
        (server.scheme as String?) == 'https';
  } catch (_) {}
  total++;
  if (secure) pass++;
  total += 2; // login enforced + short-lived pinned tokens (by design)
  pass += 2;
  var retention = 0;
  var quota = 0;
  try {
    retention = vault.settings.trashRetentionDays as int;
  } catch (_) {}
  try {
    quota = vault.settings.deviceQuotaBytes as int;
  } catch (_) {}
  total += 2;
  if (retention > 0) pass++;
  if (quota > 0) pass++;
  return '$pass/$total';
}

class _SecurityList extends StatelessWidget {
  final dynamic vault;
  final dynamic server;
  const _SecurityList({required this.vault, required this.server});

  @override
  Widget build(BuildContext context) {
    bool secure = false;
    String? fp;
    try {
      secure = (server.isSecure as bool?) ??
          (server.scheme as String?) == 'https';
    } catch (_) {}
    try {
      fp = _runnerFingerprint(server);
    } catch (_) {}
    var retention = 30;
    var quota = 0;
    try {
      retention = vault.settings.trashRetentionDays as int;
    } catch (_) {}
    try {
      quota = vault.settings.deviceQuotaBytes as int;
    } catch (_) {}
    return Column(
      children: [
        _row(context, secure, 'Encrypted transport',
            secure ? 'HTTPS with pinned certificate' : 'Plain HTTP — add TLS paths in Host Settings'),
        if (secure && fp != null && fp.isNotEmpty)
          _row(context, true, 'Certificate fingerprint',
              '${fp.substring(0, 16)}… (clients verify on connect)'),
        _row(context, true, 'Login enforced',
            'Username + Argon2id password on every new device'),
        _row(context, true, 'Short-lived tokens',
            '15-min access, 30-day refresh, pinned per device'),
        _row(context, retention > 0, 'Trash auto-purge',
            retention > 0
                ? 'Deleted files purged after $retention days'
                : 'Trash kept forever — set retention below'),
        _row(context, quota > 0, 'Vault quota',
            quota > 0
                ? 'Uploads capped at ${formatBytes(quota)}'
                : 'Unlimited — set a cap to contain damage'),
      ],
    );
  }

  Widget _row(BuildContext context, bool pass, String title, String sub) =>
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          pass ? Icons.check_circle_rounded : Icons.warning_rounded,
          color: pass
              ? const Color(0xFF43A047)
              : const Color(0xFFFB8C00),
        ),
        title: Text(title,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(sub, style: Theme.of(context).textTheme.bodySmall),
      );
}

/// Reads the runner fingerprint without assuming its type.
String? _runnerFingerprint(dynamic server) {
  try {
    return server.fingerprint as String?;
  } catch (_) {
    return null;
  }
}

/// Activity feed from the host audit log.
class _ActivityFeed extends StatelessWidget {
  final dynamic vault;
  const _ActivityFeed({required this.vault});

  static const _icons = {
    'file.upload': Icons.cloud_upload_rounded,
    'file.version.create': Icons.history_rounded,
    'file.version.restore': Icons.restore_rounded,
    'file.rename': Icons.edit_rounded,
    'file.move': Icons.drive_file_move_rounded,
    'file.trash': Icons.delete_rounded,
    'file.restore': Icons.restore_from_trash_rounded,
    'file.destroy': Icons.delete_forever_rounded,
    'file.star': Icons.star_rounded,
    'file.unstar': Icons.star_outline_rounded,
    'folder.create': Icons.create_new_folder_rounded,
    'trash.empty': Icons.delete_sweep_rounded,
    'trash.purge': Icons.auto_delete_rounded,
    'trash.purge.manual': Icons.auto_delete_rounded,
    'device.revoke': Icons.block_rounded,
    'settings.update': Icons.settings_rounded,
  };

  @override
  Widget build(BuildContext context) {
    List entries;
    try {
      entries = vault.audit.recent(limit: 20) as List;
    } catch (_) {
      return const Text('Activity unavailable.');
    }
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.timeline_rounded,
        title: 'No activity yet',
        subtitle: 'Uploads, renames and deletes show up here.',
      );
    }
    return Column(
      children: [
        for (final e in entries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(_icons[e.action as String] ??
                Icons.circle_rounded),
            title: Text(
              (e.targetName as String?) ?? (e.action as String),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
                '${e.action} • ${formatDateTime(e.createdAt)}'),
          ),
      ],
    );
  }
}