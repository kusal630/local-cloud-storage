import 'dart:io';

import '../errors/app_exceptions.dart';

/// Utilities that keep file operations inside the vault directory and prevent
/// path traversal attacks.
abstract class PathGuard {
  PathGuard._();

  /// Validates that [relativePath] stays inside [root].
  ///
  /// Throws [ValidationException] when the path attempts to escape the root.
  static String resolveInside(Directory root, String relativePath) {
    final rootNorm = normalize(root.path);
    final candidate = normalize('$rootNorm${Platform.pathSeparator}$relativePath');

    final rootParts = rootNorm.split(Platform.pathSeparator);
    final candidateParts = candidate.split(Platform.pathSeparator);

    if (candidateParts.length <= rootParts.length) {
      throw const ValidationException('Path escapes the vault directory.');
    }
    for (var i = 0; i < rootParts.length; i++) {
      if (rootParts[i] != candidateParts[i]) {
        throw const ValidationException('Path escapes the vault directory.');
      }
    }
    if (candidateParts.any((part) => part == '..')) {
      throw const ValidationException('Path must not contain "..".');
    }
    return candidate;
  }

  /// Builds the safe relative blob path for a blob id:
  /// `blobs/<first2>/<next2>/<uuid>`.
  static String blobRelativePath(String blobId) {
    _requireUuid(blobId);
    final a = blobId.substring(0, 2);
    final b = blobId.substring(2, 4);
    return 'blobs/$a/$b/$blobId';
  }

  static void _requireUuid(String id) {
    if (!RegExp(r'^[0-9a-fA-F-]{8,64}$').hasMatch(id)) {
      throw const ValidationException('Invalid blob id.');
    }
  }

  /// Returns the normalized form of [path].
  static String normalize(String path) {
    final normalized = path
        .replaceAll(r'\', '/')
        .split('/')
        .fold<List<String>>([], (acc, part) {
          if (part.isEmpty || part == '.') return acc;
          if (part == '..') {
            if (acc.isNotEmpty) acc.removeLast();
            return acc;
          }
          acc.add(part);
          return acc;
        })
        .join(Platform.pathSeparator);
    final isAbsolute = path.startsWith('/') || path.startsWith(r'\');
    final prefix = isAbsolute ? Platform.pathSeparator : '';
    return prefix + normalized;
  }
}