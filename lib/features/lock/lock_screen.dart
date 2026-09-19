import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
  bool _unlocking = false;
  int _attempts = 0;

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
        setState(() => _unlocking = true);
        await Future.delayed(const Duration(milliseconds: 300));
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
    if (_controller.text.trim().isEmpty) return;
    setState(() {
      _unlocking = true;
      _error = null;
    });
    final ok = await PinStore().verify(_controller.text.trim());
    if (!mounted) return;
    if (ok) {
      await Future.delayed(const Duration(milliseconds: 200));
      widget.onUnlocked();
    } else {
      HapticFeedback.mediumImpact();
      _attempts++;
      setState(() {
        _unlocking = false;
        _error = _attempts >= 5
            ? 'Too many attempts. Wait a moment.'
            : 'Wrong PIN. Try again.';
      });
      _controller.clear();
      if (_attempts >= 5) {
        await Future.delayed(const Duration(seconds: 5));
        if (mounted) setState(() => _attempts = 0);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
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
                  const AppLogo(size: 80)
                      .animate()
                      .scale(
                        duration: 500.ms,
                        curve: Curves.easeOutBack,
                      ),
                  const SizedBox(height: 20),
                  Text(
                    'LocalVault',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                  )
                      .animate()
                      .fadeIn(delay: 200.ms, duration: 400.ms),
                  const SizedBox(height: 6),
                  Text(
                    'Enter PIN to unlock',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  )
                      .animate()
                      .fadeIn(delay: 300.ms, duration: 400.ms),
                  const SizedBox(height: 32),
                  TextField(
                    controller: _controller,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: 8,
                    autofocus: true,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          letterSpacing: 8,
                          fontWeight: FontWeight.w700,
                        ),
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                      prefixIcon: const Icon(Icons.lock_rounded),
                      suffixIcon: _unlocking
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            )
                          : null,
                    ),
                    onSubmitted: (_) => _unlock(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        style: TextStyle(
                          color: scheme.error,
                          fontWeight: FontWeight.w600,
                        ))
                        .animate()
                        .fadeIn(duration: 200.ms)
                        .shake(delay: 50.ms),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _unlocking ? null : _unlock,
                      icon: _unlocking
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ))
                          : const Icon(Icons.lock_open_rounded),
                      label: const Text('Unlock'),
                    ),
                  )
                      .animate()
                      .fadeIn(delay: 400.ms, duration: 400.ms)
                      .slideY(begin: 0.2, end: 0),
                  if (_bioAvailable) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _unlocking ? null : () => _unlockBio(),
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: const Text('Use biometrics'),
                      ),
                    )
                        .animate()
                        .fadeIn(delay: 500.ms, duration: 400.ms),
                  ],
                  const SizedBox(height: 24),
                  Text(
                    'Your data stays on this device.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.outline,
                        ),
                  )
                      .animate()
                      .fadeIn(delay: 600.ms, duration: 400.ms),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
