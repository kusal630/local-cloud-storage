import 'dart:collection';

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';

/// In-memory, per-IP sliding-window rate limiter.
///
/// Each attempt is timestamped; a request is allowed when fewer than
/// [limit] attempts happened within the last minute.
class RateLimiter {
  RateLimiter({required this.name, required this.limit});

  final String name;
  final int limit;

  final Map<String, List<int>> _attempts = HashMap();

  /// Records an attempt for [key] and returns true when allowed.
  bool allow(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cutoff = now - 60000;
    final list = _attempts.putIfAbsent(key, () => []);
    list.removeWhere((t) => t < cutoff);
    if (list.length >= limit) {
      logWarn('Rate limit "$name" exceeded for $key');
      return false;
    }
    list.add(now);
    return true;
  }

  void reset(String key) {
    _attempts.remove(key);
  }
}

/// Tracks issued pairing codes with expiry.
///
/// A pairing code is valid for [AppConstants.pairingCodeLifetime] and can be
/// consumed only once.
class PairingCodeStore {
  PairingCodeStore();

  final Map<String, ({String code, DateTime expiresAt, String deviceId})>
      _codes = HashMap();

  String issue({required String deviceId}) {
    var code = '';
    do {
      code = Cipher.randomDigits(AppConstants.pairingCodeLength);
    } while (_codes.containsKey(code));
    _codes[code] = (
      code: code,
      expiresAt: DateTime.now().add(AppConstants.pairingCodeLifetime),
      deviceId: deviceId,
    );
    logInfo('Issued pairing code for device $deviceId');
    return code;
  }

  /// Returns the device id the code belongs to, or null when invalid/expired.
  String? consume(String code) {
    if (code.length != AppConstants.pairingCodeLength ||
        !RegExp(r'^\d{6}$').hasMatch(code)) {
      return null;
    }
    final entry = _codes.remove(code);
    if (entry == null) return null;
    if (entry.expiresAt.isBefore(DateTime.now())) {
      logWarn('Pairing code expired');
      return null;
    }
    return entry.deviceId;
  }

  /// The currently active code for [deviceId], if any.
  String? currentCodeFor(String deviceId) {
    final now = DateTime.now();
    _codes.removeWhere((_, e) => e.expiresAt.isBefore(now));
    for (final entry in _codes.entries) {
      if (entry.value.deviceId == deviceId) return entry.value.code;
    }
    return null;
  }
}