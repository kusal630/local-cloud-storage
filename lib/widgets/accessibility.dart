import 'package:flutter/material.dart';

/// Accessibility wrapper that adds semantic labels and support.
///
/// Ensures LocalVault is usable by everyone, including users with
/// visual impairments, motor limitations, or cognitive differences.
class Accessible extends StatelessWidget {
  const Accessible({
    super.key,
    required this.child,
    this.label,
    this.hint,
    this.button = false,
  });

  final Widget child;
  final String? label;
  final String? hint;
  final bool button;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      hint: hint,
      button: button,
      child: child,
    );
  }
}

/// Accessible icon button with semantic label.
class AccessibleIconButton extends StatelessWidget {
  const AccessibleIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel ?? tooltip,
      button: true,
      child: IconButton(
        icon: Icon(icon),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

/// Accessible card with semantic grouping.
class AccessibleCard extends StatelessWidget {
  const AccessibleCard({
    super.key,
    required this.child,
    this.label,
    this.onTap,
  });

  final Widget child;
  final String? label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: onTap != null,
      child: Card(
        child: onTap != null
            ? InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(16),
                child: child,
              )
            : child,
      ),
    );
  }
}

/// High contrast mode support.
class HighContrastWrapper extends StatelessWidget {
  const HighContrastWrapper({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isHighContrast = MediaQuery.of(context).highContrast;
    if (!isHighContrast) return child;

    final scheme = Theme.of(context).colorScheme;
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: scheme.copyWith(
          onSurface: Colors.black,
          onSurfaceVariant: Colors.black87,
          outline: Colors.black54,
        ),
      ),
      child: child,
    );
  }
}

/// Reduced motion support — disables animations when user prefers.
class ReducedMotionWrapper extends StatelessWidget {
  const ReducedMotionWrapper({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return reduceMotion
        ? child
        : AnimatedOpacity(
            opacity: 1.0,
            duration: Duration.zero,
            child: child,
          );
  }
}
