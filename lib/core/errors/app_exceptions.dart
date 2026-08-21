/// Base class for all application errors.
class AppException implements Exception {
  const AppException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Error while interacting with the local SQLite database.
class DatabaseException extends AppException {
  const DatabaseException(super.message, {super.cause});
}

/// Error raised for invalid user input.
class ValidationException extends AppException {
  const ValidationException(super.message, {super.cause});
}

/// Error raised when an entity could not be found.
class NotFoundException extends AppException {
  const NotFoundException(super.message, {super.cause});
}

/// Error raised on conflict, e.g. duplicate file name.
class ConflictException extends AppException {
  const ConflictException(super.message, {super.cause});
}

/// Authentication / authorization failure.
class AuthException extends AppException {
  const AuthException(super.message, {super.cause});
}

/// Network failure while talking to a Host server.
class NetworkException extends AppException {
  const NetworkException(super.message, {super.cause});
}

/// Server returned a non-2xx response.
class ApiException extends AppException {
  const ApiException(this.statusCode, String message, {super.cause})
      : super(message);

  final int statusCode;
}

/// Storage is unavailable (disconnected drive, missing folder, full disk...).
class StorageException extends AppException {
  const StorageException(super.message, {super.cause});
}

/// Thrown when the local server cannot start (port busy, bind failure...).
class ServerStartException extends AppException {
  const ServerStartException(super.message, {super.cause});
}