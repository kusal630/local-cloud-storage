import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../client/api_client.dart';
import '../client/session_store.dart';
import '../client/services/auth_service.dart';
import '../client/services/file_service.dart';
import '../client/services/transfer_manager.dart';
import '../data/datasources/vault.dart';
import '../data/models/storage_status.dart';
import '../server/server.dart';

// ---------------------------------------------------------------------------
// Host dashboard data
// ---------------------------------------------------------------------------

class HostDashboardData {
  final LocalVaultServer server;
  final Vault vault;
  const HostDashboardData({required this.server, required this.vault});
}

final hostStateProvider = StateProvider<HostDashboardData?>((_) => null);

// ---------------------------------------------------------------------------
// Client-side providers (used in Client Mode)
// ---------------------------------------------------------------------------

final sessionStoreProvider = Provider<SessionStore>((ref) => SessionStore());

final apiClientProvider = Provider<LocalVaultApi>((ref) {
  final api = LocalVaultApi(session: ref.watch(sessionStoreProvider));
  return api;
});

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(ref.watch(apiClientProvider));
});

final fileServiceProvider = Provider<FileService>((ref) {
  return FileService(ref.watch(apiClientProvider));
});

final transferManagerProvider = ChangeNotifierProvider<TransferManager>((ref) {
  return TransferManager(ref.watch(fileServiceProvider));
});

// ---------------------------------------------------------------------------
// Shared state holders
// ---------------------------------------------------------------------------

/// Current mode: host or client.
enum AppMode { welcome, host, client }

final appModeProvider = StateProvider<AppMode>((ref) => AppMode.welcome);

/// Current folder being browsed in client mode.
final currentFolderProvider =
    StateProvider<String>((_) => 'root');

/// Search query for file search.
final searchQueryProvider = StateProvider<String>((_) => '');

/// Cached server URL for the host dashboard.
final hostUrlProvider = StateProvider<String?>((_) => null);

/// Cached storage status for host dashboard.
final storageStatusProvider =
    FutureProvider<StorageStatus>((ref) async {
  final svc = ref.watch(fileServiceProvider);
  try {
    return await svc.storageStatus();
  } catch (_) {
    return const StorageStatus(
      total: 0, free: 0, used: 0, vaultUsage: 0, trashUsage: 0,
    );
  }
});