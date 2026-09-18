import 'package:equatable/equatable.dart';

/// A public share link for a file.
class SharedLink extends Equatable {
  const SharedLink({
    required this.tokenPrefix,
    required this.fileId,
    required this.fileName,
    required this.hasPassword,
    this.expiresAt,
    required this.createdAt,
    this.downloadCount = 0,
  });

  /// First 12 chars of the token (the full token is never listed).
  final String tokenPrefix;
  final String fileId;
  final String fileName;
  final bool hasPassword;
  final DateTime? expiresAt;
  final DateTime createdAt;
  final int downloadCount;

  @override
  List<Object?> get props => [
        tokenPrefix,
        fileId,
        fileName,
        hasPassword,
        expiresAt,
        createdAt,
        downloadCount,
      ];
}
