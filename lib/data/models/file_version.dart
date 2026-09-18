import 'package:equatable/equatable.dart';

/// One archived revision of a file's content.
class FileVersion extends Equatable {
  const FileVersion({
    required this.id,
    required this.fileId,
    required this.version,
    this.blobId,
    required this.size,
    this.checksum,
    this.mime,
    required this.createdAt,
  });

  final String id;
  final String fileId;
  final int version;
  final String? blobId;
  final int size;
  final String? checksum;
  final String? mime;
  final DateTime createdAt;

  @override
  List<Object?> get props =>
      [id, fileId, version, blobId, size, checksum, mime, createdAt];
}
