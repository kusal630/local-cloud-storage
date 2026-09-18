import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../widgets/common.dart';
import '../onboarding/onboarding_screen.dart';
import 'package:localvault/core/constants/app_constants.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});
  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  bool? _seenOnboarding;

  @override
  void initState() {
    super.initState();
    OnboardingFlow.seen().then((seen) {
      if (!mounted) return;
      setState(() => _seenOnboarding = seen);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    if (_seenOnboarding == null) {
      return const Scaffold(
          body: Center(child: CircularProgressIndicator()));
    }
    if (!_seenOnboarding!) {
      return OnboardingFlow(
          onDone: () => setState(() => _seenOnboarding = true));
    }
    return const _WelcomeBody();
  }
}

class _WelcomeBody extends ConsumerWidget {
  const _WelcomeBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                const SizedBox(height: 24),
                const Center(child: AppLogo(size: 104))
                    .animate()
                    .scale(
                        duration: 450.ms, curve: Curves.easeOutBack),
                const SizedBox(height: 20),
                Text(
                  AppConstants.appName,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                      ),
                )
                    .animate()
                    .fadeIn(delay: 120.ms, duration: 350.ms)
                    .slideY(begin: 0.3, end: 0),
                const SizedBox(height: 8),
                Text(
                  'Your private local cloud.\nNo internet. No subscriptions. Just your drive.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 16),
                const Center(
                  child: StatusPill(
                      label: 'LAN-ONLY • PRIVATE BY DESIGN',
                      color: Color(0xFF0E7C7B)),
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        FilledButton.icon(
                          onPressed: () {
                            ref.read(appModeProvider.notifier).state =
                                AppMode.host;
                            context.push('/host/setup');
                          },
                          icon: const Icon(Icons.dns_rounded),
                          label: const Text('Start Storage Node'),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: () {
                            ref.read(appModeProvider.notifier).state =
                                AppMode.client;
                            context.push('/client/connect');
                          },
                          icon: const Icon(Icons.phone_android_rounded),
                          label: const Text('Connect to Storage Node'),
                        ),
                      ],
                    ),
                  ),
                )
                    .animate()
                    .fadeIn(delay: 220.ms, duration: 350.ms)
                    .slideY(begin: 0.4, end: 0),
                const SizedBox(height: 16),
                _FeatureRow(
                  icon: Icons.bolt_rounded,
                  title: 'Fast LAN transfers',
                  subtitle: 'Chunked uploads + resumable downloads',
                ),
                _FeatureRow(
                  icon: Icons.qr_code_2_rounded,
                  title: 'Pair in seconds',
                  subtitle: 'Scan a QR or enter a 6-digit code',
                ),
                _FeatureRow(
                  icon: Icons.lock_rounded,
                  title: 'You hold the keys',
                  subtitle: 'Argon2id + short-lived tokens on your network',
                ),
                const SizedBox(height: 16),
                Text(
                  'HOST on this phone or desktop shares storage on :8484 and keeps running in the background. CLIENT on any device browses, uploads and backs up over any route to it.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.outline,
                      ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow(
      {required this.icon, required this.title, required this.subtitle});
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: scheme.onPrimaryContainer),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700)),
                Text(subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        )),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
