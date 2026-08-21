import 'dart:io';

import 'package:dio/dio.dart';

import '../../data/models/device.dart';
import '../../data/models/storage_status.dart';
import '../../data/models/vault_file.dart';
import '../api_client.dart';

class UploadStartResponse {
  UploadStartResponse({
    required this.uploadId,
    required this.chunkSize,
    required this.received,
  });
  final String uploadId;
  final int chunkSize;
  final int received;
}

/// Wraps all file-related REST calls.
class FileService {
  FileService(this._api);

  final LocalVaultApi _api;
  Dio get _dio => _api.dio;

  Future<List<VaultFile>> listFiles(String parentId,
      {bool includeTrashed = false}) async {
    try {
      final response = await _dio.get('/files', queryParameters: {
        'parentId': parentId,
        if (includeTrashed) 'includeTrashed': 'true',
      });
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> createFolder(String parentId, String name) async {
    try {
      final response =
          await _dio.post('/files/folder', data: {'parentId': parentId, 'name': name});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> deleteFile(String id) async {
    try {
      final response = await _dio.delete('/files/$id');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> renameFile(String id, String newName) async {
    try {
      final response =
          await _dio.patch('/files/$id', data: {'name': newName});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> moveFile(String id, String newParentId) async {
    try {
      final response =
          await _dio.patch('/files/$id', data: {'parentId': newParentId});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<VaultFile>> search(String query) async {
    try {
      final response =
          await _dio.get('/search', queryParameters: {'q': query});
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<VaultFile>> listTrash() async {
    try {
      final response = await _dio.get('/trash');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> restoreFile(String id) async {
    try {
      final response = await _dio.post('/trash/$id/restore');
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> permanentDelete(String id) async {
    try {
      final response = await _dio.delete('/trash/$id');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> emptyTrash() async {
    try {
      final response = await _dio.delete('/trash');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<StorageStatus> storageStatus() async {
    try {
      final response = await _dio.get('/storage/status');
      final data = LocalVaultApi.decodeData(response);
      return StorageStatus(
        total: data['total'] as int,
        free: data['free'] as int,
        used: data['used'] as int,
        vaultUsage: data['vaultUsage'] as int,
        trashUsage: data['trashUsage'] as int,
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<Device>> listDevices() async {
    try {
      final response = await _dio.get('/devices');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseDevice).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> revokeDevice(String id) async {
    try {
      final response = await _dio.post('/devices/$id/revoke');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Upload helpers
  // ---------------------------------------------------------------------------

  Future<UploadStartResponse> uploadStart({
    required String parentId,
    required String name,
    required int size,
    required String checksum,
    String? mime,
  }) async {
    try {
      final response = await _dio.post('/files/upload/start', data: {
        'parentId': parentId,
        'name': name,
        'size': size,
        'checksum': checksum,
        if (mime != null) 'mime': mime,
      });
      final data = LocalVaultApi.decodeData(response);
      return UploadStartResponse(
        uploadId: data['uploadId'] as String,
        chunkSize: data['chunkSize'] as int,
        received: data['received'] as int,
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<int> uploadChunk(String uploadId, int offset, List<int> chunk) async {
    try {
      final formData = FormData.fromMap({
        'uploadId': uploadId,
        'offset': '$offset',
        'chunk': MultipartFile.fromBytes(chunk, filename: 'chunk'),
      });
      final response =
          await _dio.post('/files/upload/chunk', data: formData);
      final data = LocalVaultApi.decodeData(response);
      return data['received'] as int;
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<String> uploadCheckStatus(String uploadId) async {
    try {
      final response = await _dio.post('/files/upload/status',
          data: {'uploadId': uploadId});
      final data = LocalVaultApi.decodeData(response);
      return data['status'] as String;
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> uploadComplete(String uploadId) async {
    try {
      final response =
          await _dio.post('/files/upload/complete', data: {'uploadId': uploadId});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  Future<void> downloadToFile(
    String fileId,
    String destPath, {
    void Function(int received, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final file = File(destPath);
    var startByte = 0;
    if (await file.exists()) {
      startByte = await file.length();
    }
    try {
      final response = await _dio.get<ResponseBody>(
        '/files/$fileId/content',
        options: Options(
          headers: {
            if (startByte > 0) 'Range': 'bytes=$startByte-',
          },
          responseType: ResponseType.stream,
        ),
        cancelToken: cancelToken,
      );
      final data = response.data!;
      int? contentLength;
      int totalLength = startByte;
      final contentRange = response.headers.value('content-range');
      if (contentRange != null) {
        final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
        if (match != null) totalLength = int.parse(match.group(1)!);
      } else {
        final cl = response.headers.value('content-length');
        if (cl != null)         totalLength = startByte + (int.tryParse(cl) ?? 0);
      }
      contentLength = totalLength;

      final sink = file.openWrite(mode: FileMode.append);
      await for (final chunk in data.stream) {
        if (cancelToken?.isCancelled == true) break;
        sink.add(chunk);
        startByte += chunk.length;
        onProgress?.call(startByte, contentLength);
      }
      await sink.flush();
      await sink.close();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<int>> downloadBytes(String fileId,
      {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get(
        '/files/$fileId/content',
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
      );
      return (response.data as List).cast<int>();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<int>> thumbBytes(String fileId,
      {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get(
        '/files/$fileId/thumb',
        options: Options(responseType: ResponseType.bytes),
        cancelToken: cancelToken,
      );
      return (response.data as List).cast<int>();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  // ---------------------------------------------------------------------------
  // Mappers
  // ---------------------------------------------------------------------------

  static VaultFile _parseFile(Map<String, dynamic> m) => VaultFile(
        id: m['id'] as String,
        parentId: m['parentId'] as String,
        name: m['name'] as String,
        type: m['type'] as String,
        mime: m['mime'] as String?,
        size: m['size'] as int,
        checksum: m['checksum'] as String?,
        blobId: null,
        createdAt: DateTime.parse(m['createdAt'] as String),
        modifiedAt: DateTime.parse(m['modifiedAt'] as String),
        deletedAt: m['deletedAt'] == null
            ? null
            : DateTime.parse(m['deletedAt'] as String),
        hasThumb: m['hasThumb'] as bool? ?? false,
      );

  static Device _parseDevice(Map<String, dynamic> m) => Device(
        id: m['id'] as String,
        name: m['name'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
        lastSeenAt: m['lastSeenAt'] == null
            ? null
            : DateTime.parse(m['lastSeenAt'] as String),
        isCurrent: m['isCurrent'] as bool? ?? false,
      );
}