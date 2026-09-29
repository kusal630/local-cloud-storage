import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import 'providers.dart';

import '../core/utils/disk_space_compat.dart';

import '../features/client_connect/client_connect_screen.dart';
import '../features/devices/devices_screen.dart';
import '../features/files/files_screen.dart';
import '../features/host_dashboard/host_dashboard_screen.dart';
import '../features/host_setup/host_setup_screen.dart';
import '../features/preview/preview_screen.dart';
import '../features/privacy/privacy_screen.dart';
import '../features/pool/pool_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sharing/shared_links_screen.dart';
import '../features/storage/storage_screen.dart';
import '../features/transfers/transfers_screen.dart';
import '../features/trash/trash_screen.dart';
import '../features/welcome/welcome_screen.dart';

import '../widgets/activity_strip.dart';


final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Coarse device class reported to the pool registry — the contributors list
/// picks its leading glyph from it, so a laptop must not arrive claiming to
/// be a phone (DESIGN §10: prefer "device", and never lie about which).
String _deviceKind() => (Platform.isAndroid || Platform.isIOS)
    ? 'phone'
    : 'laptop';

final routerProvider = Provider<GoRouter>((ref) {
  // Auto-setup (Pi/kiosk) boots straight into the running dashboard.
  final autoHost = ref.watch(hostStateProvider);
  // Pooled cloud: one service instance for the app (the router rebuilds only
  // if its own dependencies do, which they do not).
  final pool = ref.watch(poolServiceProvider);
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: autoHost != null ? '/host/dashboard' : '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/host/setup',
        builder: (context, state) => const HostSetupScreen(),
      ),
      GoRoute(
        path: '/host/dashboard',
        builder: (context, state) => const HostDashboardScreen(),
      ),
      GoRoute(
        path: '/client/connect',
        builder: (context, state) => const ClientConnectScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            ClientShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/files',
              builder: (context, state) => const FilesScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/transfers',
              builder: (context, state) => const TransfersScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/trash',
              builder: (context, state) => const TrashScreen(),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/storage',
              builder: (context, state) => const StorageScreen(),
              routes: [
                // Pooled cloud — pushed inside the Storage branch so the
                // 5-tab NavigationBar stays visible (DESIGN §5).
                GoRoute(
                  path: 'pool',
                  builder: (context, state) => PoolScreen(
                    // Real data, real actions — see FEATURES §5: every
                    // button on this screen reaches the coordinator.
                    fetchStatus: pool.fetchStatus,
                    onRevoke: (contributor) => pool.revoke(contributor.id),
                    onQuotaChanged: (contributor, quota) =>
                        pool.setQuota(contributor.id, quota),
                    onAddDevice: () => context.push('/client/devices'),
                    // The agent owns registration, the node server and the
                    // heartbeat loop; the screen only names the quota.
                    onContribute: (quota) async {
                      final agent =
                          await ref.read(contributorAgentProvider.future);
                      await agent.start(
                        quotaBytes: quota,
                        deviceKind: _deviceKind(),
                      );
                    },
                    onStop: () async {
                      final agent =
                          await ref.read(contributorAgentProvider.future);
                      await agent.stop();
                    },
                    // Probed from the documents directory — the same volume
                    // the node will actually write to, so the slider's
                    // maximum is real rather than merely available.
                    freeSpaceOnThisDevice: () async {
                      final docs = await getApplicationDocumentsDirectory();
                      final space = await DiskSpaceCompat.getSpace(docs.path);
                      return space?.free ?? 0;
                    },
                  ),
                ),
              ],
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/client/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/client/devices',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const DevicesScreen(),
      ),
      GoRoute(
        path: '/client/preview/:fileId',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => PreviewScreen(
          fileId: state.pathParameters['fileId']!,
        ),
      ),
      GoRoute(
        path: '/client/sharing',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const SharedLinksScreen(),
      ),
      GoRoute(
        path: '/client/privacy',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => const PrivacyScreen(),
      ),
    ],
  );
});

/// Bottom-navigation shell for Client Mode screens (5 max — thumb zone).
class ClientShell extends ConsumerWidget {
  const ClientShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched so the activity strip repaints while a transfer runs — the
    // manager notifies on every queue mutation and progress tick.
    final manager = ref.watch(transferManagerProvider);
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ActivityStrip(
            tasks: manager.tasks,
            onOpen: () => navigationShell.goBranch(
              1,
              initialLocation: navigationShell.currentIndex == 1,
            ),
          ),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            // Tapping the active tab resets its stack (expected behavior).
            onDestinationSelected: (i) => navigationShell.goBranch(
              i,
              initialLocation: i == navigationShell.currentIndex,
            ),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.folder_rounded), label: 'Files'),
              NavigationDestination(
                  icon: Icon(Icons.swap_vert_circle_rounded),
                  label: 'Transfers'),
              NavigationDestination(
                  icon: Icon(Icons.delete_outline_rounded), label: 'Trash'),
              NavigationDestination(
                  icon: Icon(Icons.sd_storage_rounded), label: 'Storage'),
              NavigationDestination(
                  icon: Icon(Icons.settings_rounded), label: 'Settings'),
            ],
          ),
        ],
      ),
    );
  }
}

