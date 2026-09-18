import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:localvault/core/utils/file_kinds.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/server/server.dart';
import 'package:localvault/core/logging/app_logger.dart' as log;
import 'package:localvault/app/providers.dart';
import 'package:localvault/widgets/common.dart';

/// Transient state for the host setup process.
class HostSetupState {
  final String? storagePath;
  final String deviceName;
  final String username;
  final String password;
  final bool loading;
  final String? error;
  const HostSetupState({
    this.storagePath,
    this.deviceName = 'My LocalVault',
    this.username = '',
    this.password = '',
    this.loading = false,
    this.error,
  });
  HostSetupState copyWith({
    String? storagePath,
    String? deviceName,
    String? username,
    String? password,
    bool? loading,
    String? error,
  }) =>
      HostSetupState(
        storagePath: storagePath ?? this.storagePath,
        deviceName: deviceName ?? this.deviceName,
        username: username ?? this.username,
        password: password ?? this.password,
        loading: loading ?? this.loading,
        error: error,
      );
}

final hostSetupProvider =
    StateNotifierProvider.autoDispose<HostSetupNotifier, HostSetupState>(
        (ref) => HostSetupNotifier());

class HostSetupNotifier extends StateNotifier<HostSetupState> {
  HostSetupNotifier() : super(const HostSetupState());

  void setPath(String p) => state = state.copyWith(storagePath: p);
  void setName(String n) => state = state.copyWith(deviceName: n);
  void setUsername(String u) =>
      state = state.copyWith(username: FileKinds.sanitizeUsername(u));
  void setPassword(String p) => state = state.copyWith(password: p);

  /// On Android, default to the app's external files dir (writable without
  /// special permissions, incl. SD-card adopted storage).
  Future<void> ensureDefaultPath() async {
    if (state.storagePath != null || !Platform.isAndroid) return;
    try {
      final dir = await getExternalStorageDirectory();
      if (dir != null) setPath(dir.path);
    } catch (_) {}
  }

  Future<void> pickStorage() async {
    final result = await FilePicker.getDirectoryPath(
      dialogTitle: 'Select a storage folder or drive',
    );
    if (result != null) setPath(result);
  }

  Future<void> startServer(WidgetRef ref, BuildContext context) async {
    final path = state.storagePath;
    if (path == null || path.isEmpty) {
      state = state.copyWith(error: 'Please select a storage location.');
      return;
    }
    if (state.password.length < 6) {
      state = state.copyWith(error: 'Password must be at least 6 characters.');
      return;
    }
    if (!FileKinds.isValidUsername(state.username)) {
      state = state.copyWith(
          error: 'Username must be 3-32 chars: letters, digits, . _ -');
      return;
    }
    state = state.copyWith(loading: true, error: null);
    try {
      final storageRoot = Directory(path);
      final vault = await Vault.create(storageRoot);
      await vault.completeSetup(
        password: state.password,
        deviceName: state.deviceName,
        username: state.username,
      );
      final server = LocalVaultServer(vault: vault);
      final port = await server.start();
      ref.read(hostUrlProvider.notifier).state =
          (await server.lanUrl()) ?? 'http://127.0.0.1:$port';
      ref.read(hostStateProvider.notifier).state = HostDashboardData(
        server: server,
        vault: vault,
      );
    } catch (e, st) {
      log.logError('Host setup failed', e, st);
      state = state.copyWith(loading: false, error: 'Setup failed: $e');
      return;
    }
    state = state.copyWith(loading: false);
    if (context.mounted) {
      ref.read(appModeProvider.notifier).state = AppMode.host;
      context.go('/host/dashboard');
    }
  }
}

class HostSetupScreen extends ConsumerStatefulWidget {
  const HostSetupScreen({super.key});
  @override
  ConsumerState<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends ConsumerState<HostSetupScreen> {
  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  late final TextEditingController _passwordController;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    final s = ref.read(hostSetupProvider);
    _nameController = TextEditingController(text: s.deviceName);
    _usernameController = TextEditingController(text: s.username);
    _passwordController = TextEditingController(text: s.password);
    Future.microtask(
        () => ref.read(hostSetupProvider.notifier).ensureDefaultPath());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  double get _strength {
    final p = ref.watch(hostSetupProvider).password;
    if (p.length < 6) return 0.15;
    double v = 0.3;
    if (p.length >= 10) v += 0.25;
    if (RegExp(r'[A-Z]').hasMatch(p)) v += 0.15;
    if (RegExp(r'[0-9]').hasMatch(p)) v += 0.15;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(p)) v += 0.15;
    return v.clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(hostSetupProvider);
    final notifier = ref.read(hostSetupProvider.notifier);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Host Setup')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const SectionHeader(title: 'STEP 1 OF 2 — STORAGE'),
                Card(
                  child: ListTile(
                    leading: VaultFileIcon(
                        name: 'drive', isFolder: true, size: 40),
                    title: Text(state.storagePath ?? 'No location selected',
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: const Text(
                        'Pick an SSD, pen drive, SD card or folder'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: notifier.pickStorage,
                  ),
                ),
                const SizedBox(height: 24),
                const SectionHeader(title: 'STEP 2 OF 2 — IDENTITY'),
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Device name',
                    hintText: 'My LocalVault',
                    prefixIcon: Icon(Icons.computer_rounded),
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: notifier.setName,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username (for cloud login)',
                    hintText: 'e.g. kusal',
                    prefixIcon: Icon(Icons.person_rounded),
                  ),
                  textInputAction: TextInputAction.next,
                  onChanged: notifier.setUsername,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _passwordController,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    hintText: 'Min 6 characters',
                    prefixIcon: const Icon(Icons.lock_rounded),
                    suffixIcon: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onChanged: notifier.setPassword,
                ),
                const SizedBox(height: 8),
                StorageMeter(
                  fraction: _strength,
                  usedLabel:
                      'Strength: ${(_strength * 100).round()}%',
                  color: _strength < 0.4
                      ? colors.error
                      : _strength < 0.7
                          ? const Color(0xFFFB8C00)
                          : const Color(0xFF43A047),
                ),
                const SizedBox(height: 16),
                if (state.error != null)
                  Card(
                    color: colors.errorContainer.withValues(alpha: 0.6),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline_rounded,
                              color: colors.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(state.error!,
                                style: TextStyle(
                                    color: colors.onErrorContainer)),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (state.error != null) const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: state.loading
                      ? null
                      : () => notifier.startServer(ref, context),
                  icon: state.loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.rocket_launch_rounded),
                  label: Text(
                      state.loading ? 'Starting…' : 'Start Storage Node'),
                ),
                const SizedBox(height: 12),
                Text(
                  'A hidden .localvault folder (SQLite + blobs) is created inside your selection. '
                  'On Android the node keeps running in the background (foreground service) so your cloud stays reachable. '
                  'Anyone on the route to this device reaches it on the shown port — share your username + password only with people you trust.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.outline),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
