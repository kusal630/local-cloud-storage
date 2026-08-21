import '../errors/app_exceptions.dart';

/// Utilities for validating and sanitizing file names.
abstract class FileNames {
  FileNames._();

  static final RegExp _controlChars = RegExp(r'[\x00-\x1f\x7f]');

  /// Reserved names that are meaningless or dangerous as a single component.
  static const Set<String> _reserved = {'.', '..'};

  /// Returns `null` when [name] is a valid vault file name, otherwise a
  /// human readable reason.
  static String? validate(String name) {
    if (name.isEmpty) {
      return 'Name cannot be empty.';
    }
    if (_reserved.contains(name)) {
      return 'Name cannot be "." or "..".';
    }
    if (name.contains('..')) {
      return 'Name cannot contain "..".';
    }
    if (name.contains('/') || name.contains(r'\')) {
      return 'Name cannot contain "/" or "\\".';
    }
    if (_controlChars.hasMatch(name)) {
      return 'Name cannot contain control characters.';
    }
    if (name.contains('\u0000')) {
      return 'Name cannot contain null bytes.';
    }
    if (name.trim() != name) {
      return 'Name cannot start or end with whitespace.';
    }
    if (name.length > 255) {
      return 'Name is too long (max 255 characters).';
    }
    return null;
  }

  /// Sanitizes a client supplied name into something safe to store.
  ///
  /// Forbidden characters are replaced, control characters are removed and the
  /// result is trimmed. An empty result throws [ValidationException].
  static String sanitize(String name) {
    var result = name;
    result = result.replaceAll(RegExp(r'[/\\]'), '_');
    result = result.replaceAll(_controlChars, '');
    result = result.replaceAll('\u0000', '');
    result = result.trim();
    result = _stripTrailingDotsAndSpaces(result);
    if (result.isEmpty || _reserved.contains(result)) {
      throw const ValidationException('Provided file name is invalid.');
    }
    if (result.length > 255) {
      result = result.substring(0, 255).trim();
    }
    return result;
  }

  static String _stripTrailingDotsAndSpaces(String value) {
    var end = value.length;
    while (end > 0 && (value.codeUnitAt(end - 1) == 0x2e || value[end - 1] == ' ')) {
      end--;
    }
    return value.substring(0, end);
  }

  /// Generates `name (n).ext` style variants for duplicate names.
  static String numberedVariant(String baseName, int attempt) {
    final dot = baseName.lastIndexOf('.');
    if (dot <= 0) {
      return '$baseName ($attempt)';
    }
    final stem = baseName.substring(0, dot);
    final extension = baseName.substring(dot);
    return '$stem ($attempt)$extension';
  }
}