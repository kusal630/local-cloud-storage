import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

import '../constants/app_constants.dart';

/// A single log entry kept in memory for the host logs screen.
class LogEntry {
  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  final DateTime timestamp;
  final String level;
  final String message;

  String get formatted =>
      '${timestamp.toIso8601String()} [$level] $message';
}

/// In-memory ring buffer that holds the most recent log lines.
class LogStore extends ChangeNotifier {
  LogStore({this.capacity = AppConstants.logBufferCapacity});

  final int capacity;
  final List<LogEntry> _entries = [];

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeRange(0, _entries.length - capacity);
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

/// Application-wide logger.
///
/// Logs go to the console and, when [attachStore] has been called, to an
/// in-memory [LogStore] consumed by the host logs screen.
class AppLogger {
  AppLogger._();

  static final AppLogger instance = AppLogger._();

  final Logger _logger = Logger(
    printer: PrettyPrinter(
      methodCount: 1,
      errorMethodCount: 4,
      lineLength: 120,
      colors: false,
      dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
    ),
    level: Level.debug,
  );

  final List<LogStore> _stores = [];

  /// Attaches a store that receives a copy of every log line.
  void attachStore(LogStore store) {
    _stores.add(store);
  }

  void detachStore(LogStore store) {
    _stores.remove(store);
  }

  void _broadcast(LogEntry entry) {
    for (final store in _stores) {
      store.add(entry);
    }
  }

  void debug(String message) {
    _logger.d(message);
    _broadcast(LogEntry(timestamp: DateTime.now(), level: 'DEBUG', message: message));
  }

  void info(String message) {
    _logger.i(message);
    _broadcast(LogEntry(timestamp: DateTime.now(), level: 'INFO', message: message));
  }

  void warn(String message) {
    _logger.w(message);
    _broadcast(LogEntry(timestamp: DateTime.now(), level: 'WARN', message: message));
  }

  void error(String message, [Object? error, StackTrace? stackTrace]) {
    _logger.e(message, error: error, stackTrace: stackTrace);
    final detail = error == null
        ? message
        : stackTrace == null
            ? '$message :: $error'
            : '$message :: $error\n$stackTrace';
    _broadcast(LogEntry(timestamp: DateTime.now(), level: 'ERROR', message: detail));
  }
}

/// Convenience top-level accessors.
void logDebug(String message) => AppLogger.instance.debug(message);
void logInfo(String message) => AppLogger.instance.info(message);
void logWarn(String message) => AppLogger.instance.warn(message);
void logError(String message, [Object? error, StackTrace? stackTrace]) =>
    AppLogger.instance.error(message, error, stackTrace);