import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers.dart';

import '../features/client_connect/client_connect_screen.dart';
import '../features/devices/devices_screen.dart';
import '../features/files/files_screen.dart';
import '../features/host_dashboard/host_dashboard_screen.dart';
import '../features/host_setup/host_setup_screen.dart';
import '../features/preview/preview_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/sharing/shared_links_screen.dart';
import '../features/storage/storage_screen.dart';
import '../features/transfers/transfers_screen.dart';
import '../features/trash/trash_screen.dart';
import '../features/welcome/welcome_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  // Auto-setup (Pi/kiosk) boots straight into the running dashboard.
  final autoHost = ref.watch(hostStateProvider);
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
    ],
  );
});

/// Bottom-navigation shell for Client Mode screens (5 max — thumb zone).
class ClientShell extends StatelessWidget {
  const ClientShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
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
    );
  }
}