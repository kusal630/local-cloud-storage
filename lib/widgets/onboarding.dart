import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';

/// Onboarding tooltip that guides users through features.
class OnboardingTooltip extends StatefulWidget {
  const OnboardingTooltip({
    super.key,
    required this.message,
    required this.child,
    this.showAgain = false,
  });

  final String message;
  final Widget child;
  final bool showAgain;

  @override
  State<OnboardingTooltip> createState() => _OnboardingTooltipState();
}

class _OnboardingTooltipState extends State<OnboardingTooltip> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        widget.child,
        Positioned(
          top: -4,
          right: -4,
          child: GestureDetector(
            onTap: () {
              AppHaptics.light();
              setState(() => _dismissed = true);
            },
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.lightbulb_rounded,
                size: 14,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Feature highlight card for onboarding.
class FeatureHighlight extends StatelessWidget {
  const FeatureHighlight({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String description;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: scheme.onPrimaryContainer, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    description,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            if (action != null && onAction != null)
              TextButton(
                onPressed: () {
                  AppHaptics.light();
                  onAction!();
                },
                child: Text(action!),
              ),
          ],
        ),
      ),
    );
  }
}

/// Quick action floating button for common tasks.
class QuickActionFab extends StatelessWidget {
  const QuickActionFab({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.mini = false,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final bool mini;

  @override
  Widget build(BuildContext context) {
    return mini
        ? FloatingActionButton.small(
            onPressed: () {
              AppHaptics.light();
              onPressed();
            },
            tooltip: label,
            child: Icon(icon),
          )
        : FloatingActionButton.extended(
            onPressed: () {
              AppHaptics.light();
              onPressed();
            },
            icon: Icon(icon),
            label: Text(label),
          );
  }
}
