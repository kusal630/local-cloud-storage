import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:localvault/app/app.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/pin_store.dart';
import 'package:localvault/client/services/backup_service.dart';
import 'package:localvault/widgets/common.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _hasPin = false;
  bool _bioOn = false;
  bool _bioSupported = false;
  int _autoLock = 2;

  @override
  void initState() {
    super.initState();
    _refreshPin();
  }

  Future<void> _refreshPin() async {
    final store = PinStore();
    final has = await store.hasPin;
    final bio = await store.biometricEnabled;
    final lock = await store.autoLockMinutes;
    bool supported = false;
    try {
      supported = await LocalAuthentication().isDeviceSupported();
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _hasPin = has;
      _bioOn = bio;
      _bioSupported = supported;
      _autoLock = lock;
    });
  }

  Future<void> _toggleBio(bool value) async {
    if (value && !_hasPin) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Set an app PIN first.')),
      );
      return;
    }
    await PinStore().setBiometricEnabled(value);
    _refreshPin();
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
              if (_bioSupported)
                SwitchListTile(
                  secondary: const Icon(Icons.fingerprint_rounded),
                  title: const Text('Biometric unlock'),
                  subtitle: const Text(
                      'Fingerprint / face instead of PIN'),
                  value: _bioOn && _hasPin,
                  onChanged: _toggleBio,
                ),
              if (_hasPin) ...[
                ListTile(
                  leading: const Icon(Icons.timer_rounded),
                  title: const Text('Auto-lock'),
                  subtitle: Text(_autoLock <= 0
                      ? 'Only on restart'
                      : 'After $_autoLock min in background'),
                  trailing: DropdownButton<int>(
                    value: _autoLock,
                    items: const [
                      DropdownMenuItem(
                          value: 0, child: Text('Restart')),
                      DropdownMenuItem(
                          value: 1, child: Text('1 min')),
                      DropdownMenuItem(
                          value: 2, child: Text('2 min')),
                      DropdownMenuItem(
                          value: 5, child: Text('5 min')),
                      DropdownMenuItem(
                          value: 15, child: Text('15 min')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      await PinStore().setAutoLockMinutes(v);
                      _refreshPin();
                    },
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.lock_rounded),
                  title: const Text('Lock now'),
                  onTap: () => ref
                      .read(lockNowProvider.notifier)
                      .state++,
                ),
              ],
              _SettingsTile(
                icon: Icons.privacy_tip_rounded,
                title: 'Privacy center',
                subtitle: 'See and delete on-device data',
                onTap: () => context.push('/client/privacy'),
              ),
            ],
          ),
          const _BackupSection(),
          _SettingsSection(
            title: 'Sharing',
            children: [
              _SettingsTile(
                icon: Icons.link_rounded,
                title: 'Shared links',
                subtitle: 'Manage expiring file links',
                onTap: () => context.push('/client/sharing'),
              ),
              _SettingsTile(
                icon: Icons.devices_rounded,
                title: 'Devices',
                subtitle: 'Paired phones, PCs and API tokens',
                onTap: () => context.push('/client/devices'),
              ),
            ],
          ),
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
                subtitle: 'Version 1.7.0',
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
      applicationVersion: '1.7.0',
      children: [
        const Text(
          'LocalVault turns local storage into a private local cloud. '
          'No internet access is required — all data stays on your device.',
        ),
        const SizedBox(height: 16),
        const Text('Built with Flutter and Dart.'),
        const SizedBox(height: 8),
        Text(
          'Your files never leave your devices.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
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
        SwitchListTile(
          secondary: const Icon(Icons.date_range_rounded),
          title: const Text('Organize by month'),
          subtitle: const Text('Uploads land in YYYY-MM folders'),
          value: backup.organizeByMonth,
          onChanged: (v) => ref
              .read(backupServiceProvider)
              .setOrganizeByMonth(v),
        ),
        if (BackupService.supportsBackground)
          SwitchListTile(
            secondary: const Icon(Icons.bedtime_rounded),
            title: const Text('Background backup'),
            subtitle: const Text(
                'System runs backup roughly every 6 hours'),
            value: backup.backgroundEnabled,
            onChanged: (v) => ref
                .read(backupServiceProvider)
                .setBackgroundEnabled(v),
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
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: TextField(
            controller: TextEditingController(
                text: backup.ignorePatterns.join(', ')),
            decoration: const InputDecoration(
              labelText: 'Ignore patterns (comma-separated, * = wildcard)',
              hintText: '*.tmp, Screenshots, thumb',
              prefixIcon: Icon(Icons.block_rounded),
            ),
            onSubmitted: (v) => ref
                .read(backupServiceProvider)
                .setIgnorePatterns(v),
          ),
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