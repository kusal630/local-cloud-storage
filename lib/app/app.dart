import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../client/pin_store.dart';
import '../features/lock/lock_screen.dart';
import 'router.dart';
import 'theme.dart';

class LocalVaultApp extends ConsumerStatefulWidget {
  const LocalVaultApp({super.key});
  @override
  ConsumerState<LocalVaultApp> createState() => _LocalVaultAppState();
}

class _LocalVaultAppState extends ConsumerState<LocalVaultApp> {
  bool? _locked;

  @override
  void initState() {
    super.initState();
    _checkLock();
  }

  Future<void> _checkLock() async {
    try {
      final has = await PinStore().hasPin;
      if (!mounted) return;
      setState(() => _locked = has);
    } catch (_) {
      // E.g. prefs unavailable in widget tests: stay unlocked.
      if (!mounted) return;
      setState(() => _locked = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_locked == null) {
      return MaterialApp(
        theme: lightTheme,
        darkTheme: darkTheme,
        debugShowCheckedModeBanner: false,
        home: const Scaffold(
            body: Center(child: CircularProgressIndicator())),
      );
    }
    if (_locked == true) {
      return MaterialApp(
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: ref.watch(themeModeProvider),
        debugShowCheckedModeBanner: false,
        home: LockScreen(onUnlocked: () => setState(() => _locked = false)),
      );
    }
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      title: 'LocalVault',
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: themeMode,
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}

/// Theme mode state.
final themeModeProvider = StateProvider<ThemeMode>((_) => ThemeMode.system);