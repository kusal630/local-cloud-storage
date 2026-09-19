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
  static Future<void> success() async {
    try {
      await services.HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 80));
      await services.HapticFeedback.mediumImpact();
    } catch (_) {}
  }

  /// Error pattern — failed upload, connection lost, invalid input.
  static Future<void> error() async {
    try {
      await services.HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await services.HapticFeedback.heavyImpact();
      await Future.delayed(const Duration(milliseconds: 100));
      await services.HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  /// Selection changed — multi-select toggle, filter change.
  static Future<void> selection() async {
    try {
      await services.HapticFeedback.selectionClick();
    } catch (_) {}
  }
}
