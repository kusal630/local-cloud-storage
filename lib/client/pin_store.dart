import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Client-side app PIN lock. The PIN is never stored — only its SHA-256 hash
/// in SharedPreferences. No new dependencies (uses `crypto` + prefs).
class PinStore {
  static const String _hashKey = 'app_pin_hash';
  static const String _bioKey = 'app_biometric_unlock';

  Future<bool> get hasPin async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_hashKey) ?? '').isNotEmpty;
  }

  static String hashOf(String pin) =>
      sha256.convert(utf8.encode('localvault-pin:$pin')).toString();

  Future<void> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_hashKey, hashOf(pin));
  }

  Future<bool> verify(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_hashKey) ?? '';
    if (stored.isEmpty) return true;
    return stored == hashOf(pin);
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_hashKey);
    await prefs.remove(_bioKey);
  }

  Future<bool> get biometricEnabled async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_bioKey) ?? false;
  }

  Future<void> setBiometricEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_bioKey, value);
  }
}
