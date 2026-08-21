import 'package:equatable/equatable.dart';

/// Metadata for a file or folder stored in the vault.
class VaultFile extends Equatable {
  const VaultFile({
    required this.id,
    required this.parentId,
    required this.name,
    required this.type,
    required this.size,
    required this.createdAt,
    required this.modifiedAt,
    this.mime,
    this.checksum,
    this.blobId,
    this.deletedAt,
    this.hasThumb = false,
  });

  final String id;
  final String parentId;
  final String name;

  /// `file` or `folder`.
  final String type;

  final int size;
  final String? mime;
  final String? checksum;
  final String? blobId;
  final DateTime createdAt;
  final DateTime modifiedAt;
  final DateTime? deletedAt;
  final bool hasThumb;

  bool get isFolder => type == 'folder';

  bool get isTrashed => deletedAt != null;

  @override
  List<Object?> get props => [
        id,
        parentId,
        name,
        type,
        size,
        mime,
        checksum,
        blobId,
        createdAt,
        modifiedAt,
        deletedAt,
        hasThumb,
      ];
}