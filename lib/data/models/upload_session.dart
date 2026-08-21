import 'package:equatable/equatable.dart';

/// Server side state of an in-flight chunked upload.
class UploadSession extends Equatable {
  const UploadSession({
    required this.id,
    required this.parentId,
    required this.name,
    required this.size,
    required this.expectedChecksum,
    required this.received,
    required this.status,
    this.mime,
    this.createdAt,
  });

  final String id;
  final String parentId;
  final String name;
  final int size;
  final String expectedChecksum;
  final int received;
  final String status; // active | completed | aborted
  final String? mime;
  final DateTime? createdAt;

  UploadSession copyWith({int? received, String? status}) => UploadSession(
        id: id,
        parentId: parentId,
        name: name,
        size: size,
        expectedChecksum: expectedChecksum,
        received: received ?? this.received,
        status: status ?? this.status,
        mime: mime,
        createdAt: createdAt,
      );

  @override
  List<Object?> get props => [
        id,
        parentId,
        name,
        size,
        expectedChecksum,
        received,
        status,
        mime,
        createdAt,
      ];
}