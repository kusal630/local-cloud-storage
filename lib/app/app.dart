import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../client/pin_store.dart';
import '../features/lock/lock_screen.dart';
import 'providers.dart';
import 'router.dart';
import 'theme.dart';

class LocalVaultApp extends ConsumerStatefulWidget {
  const LocalVaultApp({super.key});
  @override
  ConsumerState<LocalVaultApp> createState() => _LocalVaultAppState();
}

class _LocalVaultAppState extends ConsumerState<LocalVaultApp> {
  bool? _locked;
  StreamSubscription<List<SharedMediaFile>>? _sharedSub;

  @override
  void initState() {
    super.initState();
    _checkLock();
    _initSharedIntent();
  }

  @override
  void dispose() {
    _sharedSub?.cancel();
    super.dispose();
  }

  /// Files/text shared from other apps (Android share sheet) are queued
  /// straight into the current cloud folder.
  void _initSharedIntent() {
    try {
      ReceiveSharingIntent.instance
          .getInitialMedia()
          .then(_handleShared)
          .catchError((_) => <SharedMediaFile>[]);
      _sharedSub = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen(_handleShared, onError: (_) {});
    } catch (_) {}
  }

  Future<void> _handleShared(List<SharedMediaFile> files) async {
    if (files.isEmpty) return;
    var queued = 0;
    for (final f in files) {
      try {
        if (f.type == SharedMediaType.text ||
            f.type == SharedMediaType.url) {
          final text = f.path.trim();
          if (text.isEmpty) continue;
          final docs = await getApplicationDocumentsDirectory();
          final dir = Directory(p.join(docs.path, 'notes'));
          await dir.create(recursive: true);
          final path = p.join(dir.path,
              'shared-${DateTime.now().millisecondsSinceEpoch}.txt');
          await File(path).writeAsString(text);
          ref.read(transferManagerProvider).enqueueUpload(
                sourcePath: path,
                parentId: ref.read(currentFolderProvider),
                name: p.basename(path),
              );
        } else {
          final path = f.path;
          if (!await File(path).exists()) continue;
          ref.read(transferManagerProvider).enqueueUpload(
                sourcePath: path,
                parentId: ref.read(currentFolderProvider),
                name: p.basename(path),
              );
        }
        queued++;
      } catch (_) {}
    }
    if (queued > 0 && mounted) {
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
              content:
                  Text('$queued shared file(s) queued — see Transfers')),
        );
      }
    }
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