import 'package:flutter/services.dart' as services;

/// World-class haptic feedback system.
///
/// Provides distinct tactile patterns for different interactions,
/// creating a premium feel that users associate with high-quality apps.
/// Light taps for navigation, medium for actions, heavy for destructive.
class AppHaptics {
  AppHaptics._();

  /// Light tap — button presses, toggle switches, tab switches.
  static Future<void> light() async {
    try {
      await services.HapticFeedback.lightImpact();
    } catch (_) {}
  }

  /// Medium tap — file selection, star toggle, confirm actions.
  static Future<void> medium() async {
    try {
      await services.HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  /// Heavy tap — destructive actions, long-press start, drag start.
  static Future<void> heavy() async {
    try {
      await services.HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  /// Success pattern — upload complete, file shared, backup done.
  ///
  /// The platform's success notification is a *system* cue: recognisably
  /// different from a UI tap, so "the transfer finished" is unmistakable
  /// without looking at the screen. Desktop/web embedders that do not
  /// implement it fall back to the original double tap.
  static Future<void> success() => _pattern(
        services.HapticFeedback.successNotification,
        () async {
          await services.HapticFeedback.mediumImpact();
          await Future.delayed(const Duration(milliseconds: 80));
          await services.HapticFeedback.mediumImpact();
        },
      );

  /// Error pattern — failed upload, connection lost, invalid input.
  ///
  /// [services.HapticFeedback.errorNotification] first, with the original
  /// triple heavy tap as the fallback (see [success]).
  static Future<void> error() => _pattern(
        services.HapticFeedback.errorNotification,
        () async {
          await services.HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 100));
          await services.HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 100));
          await services.HapticFeedback.heavyImpact();
        },
      );

  /// Warning pattern — pool filling up, device offline, quota close to full.
  ///
  /// Softer than [error] on purpose: a warning asks for attention, an error
  /// announces a failure. Falls back to a heavy-then-light pair (the same
  /// two-beat shape as [success], heavier on the first beat so it reads as
  /// "check this").
  static Future<void> warning() => _pattern(
        services.HapticFeedback.warningNotification,
        () async {
          await services.HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 90));
          await services.HapticFeedback.lightImpact();
        },
      );

  /// Selection changed — multi-select toggle, filter change.
  static Future<void> selection() async {
    try {
      await services.HapticFeedback.selectionClick();
    } catch (_) {}
  }

  /// Plays the platform's named notification pattern, and only falls back to
  /// the hand-rolled sequence when the platform channel rejects the call
  /// (embedders without an implementation) — so Android/iOS get exactly one
  /// pattern, never two stacked on top of each other.
  static Future<void> _pattern(
    Future<void> Function() system,
    Future<void> Function() fallback,
  ) async {
    try {
      await system();
    } catch (_) {
      try {
        await fallback();
      } catch (_) {}
    }
  }
}
