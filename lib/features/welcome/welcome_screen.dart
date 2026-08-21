import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import 'package:localvault/core/constants/app_constants.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Icon(
                Icons.cloud_off_outlined,
                size: 96,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                AppConstants.appName,
                style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your private local cloud storage',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.outline,
                    ),
              ),
              const Spacer(flex: 3),
              FilledButton.icon(
                onPressed: () {
                  ref.read(appModeProvider.notifier).state = AppMode.host;
                  context.push('/host/setup');
                },
                icon: const Icon(Icons.dns),
                label: const Text('Start Storage Node'),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () {
                  ref.read(appModeProvider.notifier).state = AppMode.client;
                  context.push('/client/connect');
                },
                icon: const Icon(Icons.phone_android),
                label: const Text('Connect to Storage Node'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}