import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../client/api_client.dart';
import '../client/session_store.dart';
import '../client/services/auth_service.dart';
import '../client/services/backup_service.dart';
import '../client/services/contributor_agent.dart';
import '../client/services/file_service.dart';
import '../client/services/offline_service.dart';
import '../client/services/pool_service.dart';
import '../client/services/transfer_manager.dart';
import '../data/datasources/vault.dart';
import '../data/models/storage_status.dart';

// ---------------------------------------------------------------------------
// Host dashboard data
// ---------------------------------------------------------------------------

class HostDashboardData {
  /// [server] is a [HostRunner] (background-isolate node). Typed dynamic so
  /// the dashboard stays decoupled from the runner implementation.
  final dynamic server;
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

final backupServiceProvider = ChangeNotifierProvider<BackupService>((ref) {
  final svc = BackupService(
    ref.watch(fileServiceProvider),
    ref.watch(transferManagerProvider),
  );
  svc.load();
  return svc;
});

final offlineServiceProvider =
    ChangeNotifierProvider<OfflineService>((ref) {
  final svc = OfflineService(ref.watch(fileServiceProvider));
  svc.load();
  return svc;
});

// ---------------------------------------------------------------------------
// Pooled Data Cloud (v2.4.0)
// ---------------------------------------------------------------------------

/// The pool API, riding the same pinned client every other service uses.
///
/// Exactly one instance: [PoolService] installs an auth-header guard on the
/// shared Dio instance during construction, and stacking two of them would
/// strip the capability header on the way out.
final poolServiceProvider = Provider<PoolService>(
  (ref) => PoolService(ref.watch(apiClientProvider)),
);

/// This device's contributor node — the thing that actually donates disk.
///
/// Resolved once, lazily: the node needs a real directory (only path_provider
/// can name one) and it owns a server plus a heartbeat timer that must
/// outlive any single screen. Awaiting `.future` at the point of use keeps
/// the pool screen free of async provider plumbing.
final contributorAgentProvider = FutureProvider<ContributorAgent>((ref) async {
  final pool = ref.watch(poolServiceProvider);
  final docs = await getApplicationDocumentsDirectory();
  final agent = ContributorAgent(
    pool: pool,
    nodeDir: Directory(p.join(docs.path, 'pool_node')),
  );
  ref.onDispose(agent.dispose);
  return agent;
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

/// Increment to lock the app immediately (Settings → Lock now).
final lockNowProvider = StateProvider<int>((_) => 0);