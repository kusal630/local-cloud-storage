import 'package:flutter/material.dart';
import '../core/haptics/haptic_feedback.dart';

/// Haptic-aware button that triggers light haptic on tap.
class HapticButton extends StatelessWidget {
  const HapticButton({
    super.key,
    required this.onPressed,
    required this.child,
    this.style,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final ButtonStyle? style;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed == null
          ? null
          : () {
              AppHaptics.light();
              onPressed!();
            },
      style: style,
      child: child,
    );
  }
}

/// Haptic-aware icon button with light feedback on tap.
class HapticIconButton extends StatelessWidget {
  const HapticIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: tooltip,
      onPressed: onPressed == null
          ? null
          : () {
              AppHaptics.light();
              onPressed!();
            },
    );
  }
}

/// Haptic-aware list tile with light feedback on tap.
class HapticListTile extends StatelessWidget {
  const HapticListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: leading,
      title: title,
      subtitle: subtitle,
      trailing: trailing,
      onTap: onTap == null
          ? null
          : () {
              AppHaptics.light();
              onTap!();
            },
      onLongPress: onLongPress == null
          ? null
          : () {
              AppHaptics.medium();
              onLongPress!();
            },
    );
  }
}

/// Haptic-aware switch with selection feedback.
class HapticSwitch extends StatelessWidget {
  const HapticSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.title,
    this.subtitle,
    this.secondary,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Widget? title;
  final Widget? subtitle;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: secondary,
      title: title,
      subtitle: subtitle,
      value: value,
      onChanged: (v) {
        AppHaptics.selection();
        onChanged(v);
      },
    );
  }
}

/// Haptic feedback wrapper for any widget.
class HapticTap extends StatelessWidget {
  const HapticTap({
    super.key,
    required this.onTap,
    required this.child,
    this.hapticType = 'light',
  });

  final VoidCallback? onTap;
  final Widget child;
  final String hapticType;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap == null
          ? null
          : () {
              switch (hapticType) {
                case 'medium':
                  AppHaptics.medium();
                  break;
                case 'heavy':
                  AppHaptics.heavy();
                  break;
                case 'selection':
                  AppHaptics.selection();
                  break;
                default:
                  AppHaptics.light();
              }
              onTap!();
            },
      child: child,
    );
  }
}
