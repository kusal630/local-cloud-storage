import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/server/server.dart';
import 'package:localvault/core/logging/app_logger.dart' as log;
import 'package:localvault/app/providers.dart';

/// Transient state for the host setup process.
class HostSetupState {
  final String? storagePath;
  final String deviceName;
  final String password;
  final bool loading;
  final String? error;
  const HostSetupState({
    this.storagePath,
    this.deviceName = 'My LocalVault',
    this.password = '',
    this.loading = false,
    this.error,
  });
  HostSetupState copyWith({
    String? storagePath,
    String? deviceName,
    String? password,
    bool? loading,
    String? error,
  }) =>
      HostSetupState(
        storagePath: storagePath ?? this.storagePath,
        deviceName: deviceName ?? this.deviceName,
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
  void setPassword(String p) => state = state.copyWith(password: p);

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
    state = state.copyWith(loading: true, error: null);
    try {
      final storageRoot = Directory(path);
      final vault = await Vault.create(storageRoot);
      await vault.completeSetup(
        password: state.password,
        deviceName: state.deviceName,
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

class HostSetupScreen extends ConsumerWidget {
  const HostSetupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(hostSetupProvider);
    final notifier = ref.read(hostSetupProvider.notifier);
    final colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Host Setup')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Storage Location',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(state.storagePath ?? 'No location selected'),
                subtitle: const Text('Tap to select a folder or drive'),
                trailing: const Icon(Icons.chevron_right),
                onTap: notifier.pickStorage,
              ),
            ),
            const SizedBox(height: 24),
            Text('Device Name',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: TextEditingController(text: state.deviceName),
              decoration:
                  const InputDecoration(hintText: 'My LocalVault'),
              onChanged: notifier.setName,
            ),
            const SizedBox(height: 24),
            Text('Password', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              obscureText: true,
              controller: TextEditingController(text: state.password),
              decoration:
                  const InputDecoration(hintText: 'Min 6 characters'),
              onChanged: notifier.setPassword,
            ),
            const SizedBox(height: 24),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  state.error!,
                  style: TextStyle(color: colors.error),
                ),
              ),
            FilledButton(
              onPressed: state.loading
                  ? null
                  : () => notifier.startServer(ref, context),
              child: state.loading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Start Storage Node'),
            ),
          ],
        ),
      ),
    );
  }
}