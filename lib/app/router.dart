import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/client_connect/client_connect_screen.dart';
import '../features/devices/devices_screen.dart';
import '../features/files/files_screen.dart';
import '../features/host_dashboard/host_dashboard_screen.dart';
import '../features/host_setup/host_setup_screen.dart';
import '../features/preview/preview_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/storage/storage_screen.dart';
import '../features/transfers/transfers_screen.dart';
import '../features/trash/trash_screen.dart';
import '../features/welcome/welcome_screen.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
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
              path: '/client/devices',
              builder: (context, state) => const DevicesScreen(),
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
        path: '/client/preview/:fileId',
        parentNavigatorKey: rootNavigatorKey,
        builder: (context, state) => PreviewScreen(
          fileId: state.pathParameters['fileId']!,
        ),
      ),
    ],
  );
});

/// Bottom-navigation shell for Client Mode screens.
class ClientShell extends StatelessWidget {
  const ClientShell({required this.navigationShell, super.key});
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: navigationShell.goBranch,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.folder), label: 'Files'),
          NavigationDestination(
              icon: Icon(Icons.swap_vert_circle_outlined), label: 'Transfers'),
          NavigationDestination(icon: Icon(Icons.delete_outline), label: 'Trash'),
          NavigationDestination(icon: Icon(Icons.devices), label: 'Devices'),
          NavigationDestination(icon: Icon(Icons.sd_storage), label: 'Storage'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}