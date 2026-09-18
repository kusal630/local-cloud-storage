import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/app/app.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/pin_store.dart';
import 'package:localvault/widgets/common.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _hasPin = false;

  @override
  void initState() {
    super.initState();
    _refreshPin();
  }

  Future<void> _refreshPin() async {
    final has = await PinStore().hasPin;
    if (!mounted) return;
    setState(() => _hasPin = has);
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _SettingsSection(
            title: 'Appearance',
            children: [
              _SettingsTile(
                icon: Icons.dark_mode,
                title: 'Theme',
                subtitle: themeMode == ThemeMode.system
                    ? 'System'
                    : themeMode == ThemeMode.dark
                        ? 'Dark'
                        : 'Light',
                onTap: () {
                  final modes = [
                    ThemeMode.system,
                    ThemeMode.light,
                    ThemeMode.dark
                  ];
                  final idx = modes.indexOf(themeMode);
                  ref.read(themeModeProvider.notifier).state =
                      modes[(idx + 1) % modes.length];
                },
              ),
            ],
          ),
          _SettingsSection(
            title: 'Security',
            children: [
              _SettingsTile(
                icon: _hasPin
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                title: 'App PIN',
                subtitle: _hasPin
                    ? 'Enabled — change or disable'
                    : 'Protect this app with a PIN',
                onTap: () => _pinSheet(),
              ),
            ],
          ),
          const _BackupSection(),
          _SettingsSection(
            title: 'Account',
            children: [
              _SettingsTile(
                icon: Icons.logout,
                title: 'Disconnect',
                subtitle: 'Disconnect from the host server',
                onTap: () => _disconnect(context, ref),
              ),
            ],
          ),
          _SettingsSection(
            title: 'About',
            children: [
              _SettingsTile(
                icon: Icons.info_outline,
                title: 'About LocalVault',
                subtitle: 'Version 1.0.0',
                onTap: () => _showAbout(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pinSheet() async {
    final first = TextEditingController();
    final second = TextEditingController();
    var confirmCurrent = false;
    if (_hasPin) {
      final current = TextEditingController();
      confirmCurrent = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Current PIN'),
              content: TextField(
                controller: current,
                obscureText: true,
                keyboardType: TextInputType.number,
                autofocus: true,
                decoration:
                    const InputDecoration(labelText: 'Enter current PIN'),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(ctx, current.text.isNotEmpty),
                    child: const Text('Next')),
              ],
            ),
          ) ??
          false;
      if (!confirmCurrent) return;
      final ok = await PinStore().verify(current.text.trim());
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Wrong PIN.')),
        );
        return;
      }
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_hasPin ? 'Change PIN' : 'Set app PIN'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: first,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration:
                  const InputDecoration(labelText: 'New PIN (4-8 digits)'),
            ),
            TextField(
              controller: second,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 8,
              decoration:
                  const InputDecoration(labelText: 'Repeat PIN'),
            ),
          ],
        ),
        actions: [
          if (_hasPin)
            TextButton(
                onPressed: () => Navigator.pop(ctx, 'disable'),
                child: const Text('Disable',
                    style: TextStyle(color: Colors.red))),
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'save'),
              child: const Text('Save')),
        ],
      ),
    );
    if (action == 'disable') {
      await PinStore().clear();
      _refreshPin();
      return;
    }
    if (action != 'save') return;
    final a = first.text.trim();
    final b = second.text.trim();
    if (a.length < 4 || a != b) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('PINs must match and be 4-8 digits.')),
      );
      return;
    }
    await PinStore().setPin(a);
    _refreshPin();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('App PIN enabled.')),
    );
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect?'),
        content: const Text('You will need to reconnect with a pairing code.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(authServiceProvider).logout();
    } catch (_) {}
    if (context.mounted) {
      ref.read(appModeProvider.notifier).state = AppMode.welcome;
      context.go('/');
    }
  }

  void _showAbout(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'LocalVault',
      applicationVersion: '1.0.0',
      children: [
        const Text(
          'LocalVault turns local storage into a private local cloud. '
          'No internet access is required — all data stays on your device.',
        ),
        const SizedBox(height: 16),
        const Text('Built with Flutter and Dart.'),
      ],
    );
  }
}

/// Auto Backup: watches chosen folders and uploads new files to
/// `Auto Backup/<device>` on the cloud. Runs while the app is open.
class _BackupSection extends ConsumerWidget {
  const _BackupSection();

  Future<void> _runNow(BuildContext context, WidgetRef ref) async {
    final session = ref.read(sessionStoreProvider);
    final deviceName =
        await session.getDeviceName() ?? 'device';
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(backupServiceProvider)
          .runBackup(deviceName: deviceName);
      final svc = ref.read(backupServiceProvider);
      messenger.showSnackBar(
        SnackBar(
            content: Text(
                'Backup done: ${svc.lastAdded} new, ${svc.lastScanned} scanned.')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final backup = ref.watch(backupServiceProvider);
    return _SettingsSection(
      title: 'Auto Backup',
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.cloud_upload_rounded),
          title: const Text('Backup watched folders'),
          subtitle: Text(backup.lastRun == null
              ? 'New photos & files upload to Auto Backup'
              : 'Last run ${formatDateTime(backup.lastRun!)}: '
                  '${backup.lastAdded} new / ${backup.lastScanned} scanned'),
          value: backup.enabled,
          onChanged: (v) =>
              ref.read(backupServiceProvider).setEnabled(v),
        ),
        for (final src in backup.sources)
          ListTile(
            dense: true,
            leading: const Icon(Icons.folder_rounded),
            title: Text(src,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline_rounded),
              onPressed: () => ref
                  .read(backupServiceProvider)
                  .removeSource(src),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.add_rounded),
          title: const Text('Watch a folder'),
          subtitle: const Text('e.g. DCIM / Camera, Documents'),
          onTap: () async {
            final path = await FilePicker.getDirectoryPath(
              dialogTitle: 'Choose a folder to back up',
            );
            if (path != null) {
              await ref.read(backupServiceProvider).addSource(path);
            }
          },
        ),
        ListTile(
          leading: backup.running
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.play_arrow_rounded),
          title: Text(backup.running ? 'Backing up…' : 'Backup now'),
          subtitle: backup.error == null
              ? null
              : Text(backup.error!,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error)),
          onTap: backup.running ? null : () => _runNow(context, ref),
        ),
      ],
    );
  }
}

class _SettingsSection extends StatelessWidget {  final String title;
  final List<Widget> children;
  const _SettingsSection({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
            child: Text(title.toUpperCase(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    )),
          ),
          ...children,
        ],
      );
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  const _SettingsTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle!) : null,
        onTap: onTap,
      );
}