import 'dart:collection';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// LRU cache for images with size limits.
///
/// Prevents memory overflow by evicting least-recently-used items
/// when the cache exceeds [maxSize] bytes.
class ImageCache extends ChangeNotifier {
  ImageCache({this.maxSize = 50 * 1024 * 1024}); // 50 MB default

  final int maxSize;
  final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  int _currentSize = 0;

  int get currentSize => _currentSize;
  int get itemCount => _cache.length;

  /// Get cached image data.
  Uint8List? get(String key) {
    if (!_cache.containsKey(key)) return null;
    // Move to end (most recently used)
    final data = _cache.remove(key)!;
    _cache[key] = data;
    return data;
  }

  /// Add image data to cache.
  void put(String key, Uint8List data) {
    if (_cache.containsKey(key)) {
      _currentSize -= _cache[key]!.length;
      _cache.remove(key);
    }

    // Evict until we have space
    while (_currentSize + data.length > maxSize && _cache.isNotEmpty) {
      final oldest = _cache.keys.first;
      final oldestData = _cache.remove(oldest)!;
      _currentSize -= oldestData.length;
    }

    _cache[key] = data;
    _currentSize += data.length;
    notifyListeners();
  }

  /// Check if key exists in cache.
  bool contains(String key) => _cache.containsKey(key);

  /// Remove specific entry.
  void remove(String key) {
    final data = _cache.remove(key);
    if (data != null) {
      _currentSize -= data.length;
      notifyListeners();
    }
  }

  /// Clear entire cache.
  void clear() {
    _cache.clear();
    _currentSize = 0;
    notifyListeners();
  }

  /// Get cache stats.
  ({int items, int sizeMB, double hitRate}) stats() => (
        items: _cache.length,
        sizeMB: (_currentSize / (1024 * 1024)).round(),
        hitRate: 0.0, // TODO: Track hits/misses
      );
}

/// Singleton image cache instance.
final imageCacheProvider = ChangeNotifierProvider<ImageCache>(
  (_) => ImageCache(),
);
