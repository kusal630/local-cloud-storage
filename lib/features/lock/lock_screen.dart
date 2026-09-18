import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../client/pin_store.dart';
import '../../widgets/common.dart';

/// Gate shown on startup when an app PIN is set.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key, required this.onUnlocked});
  final VoidCallback onUnlocked;

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _bioAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBio();
  }

  Future<void> _checkBio() async {
    try {
      if (!await PinStore().biometricEnabled) return;
      final supported = await LocalAuthentication().isDeviceSupported();
      if (!mounted || !supported) return;
      setState(() => _bioAvailable = true);
      // Offer immediately — user can fall back to PIN.
      await _unlockBio(auto: true);
    } catch (_) {}
  }

  Future<void> _unlockBio({bool auto = false}) async {
    try {
      final ok = await LocalAuthentication().authenticate(
        localizedReason: 'Unlock LocalVault',
        biometricOnly: true,
      );
      if (!mounted) return;
      if (ok) {
        widget.onUnlocked();
      } else if (!auto) {
        setState(() => _error = 'Biometric unlock failed.');
      }
    } catch (_) {
      if (!mounted || auto) return;
      setState(() => _error = 'Biometric unlock unavailable.');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _unlock() async {
    final ok = await PinStore().verify(_controller.text.trim());
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() => _error = 'Wrong PIN. Try again.');
      _controller.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const AppLogo(size: 72),
                  const SizedBox(height: 16),
                  Text('LocalVault is locked',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _controller,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'PIN',
                      prefixIcon: Icon(Icons.lock_rounded),
                    ),
                    onSubmitted: (_) => _unlock(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!,
                        style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _unlock,
                    icon: const Icon(Icons.lock_open_rounded),
                    label: const Text('Unlock'),
                  ),
                  if (_bioAvailable) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () => _unlockBio(),
                      icon: const Icon(Icons.fingerprint_rounded),
                      label: const Text('Use biometrics'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
