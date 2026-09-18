import 'package:equatable/equatable.dart';

/// A comment on a file or folder (Nextcloud-style details activity).
class FileComment extends Equatable {
  const FileComment({
    required this.id,
    required this.fileId,
    this.deviceId,
    required this.author,
    required this.body,
    required this.createdAt,
  });

  final String id;
  final String fileId;
  final String? deviceId;
  final String author;
  final String body;
  final DateTime createdAt;

  @override
  List<Object?> get props => [id, fileId, deviceId, author, body, createdAt];
}
