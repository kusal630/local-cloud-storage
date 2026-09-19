import 'dart:ui';
import 'package:flutter/material.dart';

/// Glassmorphism card — backdrop blur with frosted glass effect.
///
/// Used for premium overlays, floating panels, and hero cards.
/// Creates depth and hierarchy without heavy shadows.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.blur = 20,
    this.opacity = 0.15,
    this.borderRadius = 16,
    this.padding = const EdgeInsets.all(20),
    this.borderColor,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final EdgeInsets padding;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: (isDark ? scheme.surface : scheme.surface)
                .withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor ??
                  scheme.outlineVariant.withValues(alpha: isDark ? 0.2 : 0.3),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Frosted glass overlay for modals and bottom sheets.
class GlassOverlay extends StatelessWidget {
  const GlassOverlay({
    super.key,
    required this.child,
    this.blur = 30,
    this.opacity = 0.1,
  });

  final Widget child;
  final double blur;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          color: scheme.surface.withValues(alpha: opacity),
          child: child,
        ),
      ),
    );
  }
}

/// Glassmorphism button with frosted effect.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.blur = 15,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final String label;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Material(
          color: scheme.primaryContainer.withValues(alpha: 0.6),
          child: InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
