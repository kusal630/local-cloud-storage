import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../data/models/audit_entry.dart';
import '../../data/models/device.dart';
import '../../data/models/file_comment.dart';
import '../../data/models/file_version.dart';
import '../../data/models/shared_link.dart';
import '../../data/models/storage_status.dart';
import '../../data/models/vault_file.dart';
import '../api_client.dart';

class DuplicateFile {
  DuplicateFile({
    required this.id,
    required this.parentId,
    required this.name,
    required this.modifiedAt,
  });
  final String id;
  final String parentId;
  final String name;
  final DateTime modifiedAt;
}

class DuplicateGroup {
  DuplicateGroup({
    required this.checksum,
    required this.size,
    required this.wastedBytes,
    required this.files,
  });
  final String checksum;
  final int size;
  final int wastedBytes;
  final List<DuplicateFile> files;
}

class HostSettings {
  HostSettings({
    required this.trashRetentionDays,
    required this.deviceQuotaBytes,
    required this.tlsConfigured,
    required this.shareDefaultExpiryHours,
  });
  final int trashRetentionDays;
  final int deviceQuotaBytes;
  final bool tlsConfigured;
  final int shareDefaultExpiryHours;
}

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

  Future<VaultFile> copyFile(String id, {String? parentId}) async {
    try {
      final response = await _dio.post('/files/$id/copy',
          data: {if (parentId != null) 'parentId': parentId});
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

  Future<VaultFile> setTags(String id, List<String> tags) async {
    try {
      final response =
          await _dio.patch('/files/$id/tags', data: {'tags': tags});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<({String tag, int count})>> listTags() async {
    try {
      final response = await _dio.get('/tags');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return [
        for (final m in items)
          (tag: m['tag'] as String, count: (m['count'] as num).toInt())
      ];
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<VaultFile>> listByTag(String tag) async {
    try {
      final response =
          await _dio.get('/files/by-tag', queryParameters: {'tag': tag});
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<FileComment>> listComments(String fileId) async {
    try {
      final response = await _dio.get('/files/$fileId/comments');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseComment).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<FileComment> addComment(String fileId, String body) async {
    try {
      final response =
          await _dio.post('/files/$fileId/comments', data: {'body': body});
      final data = LocalVaultApi.decodeData(response);
      return _parseComment(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> deleteComment(String fileId, String commentId) async {
    try {
      final response =
          await _dio.delete('/files/$fileId/comments/$commentId');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<AuditEntry>> activityFor(String targetId,
      {int limit = 50}) async {
    try {
      final response = await _dio.get('/activity/for',
          queryParameters: {'target': targetId, 'limit': limit});
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseAudit).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<DuplicateGroup>> listDuplicates() async {
    try {
      final response = await _dio.get('/storage/duplicates');
      final data = LocalVaultApi.decodeData(response);
      final groups = (data['groups'] as List).cast<Map<String, dynamic>>();
      return [
        for (final g in groups)
          DuplicateGroup(
            checksum: g['checksum'] as String,
            size: (g['size'] as num).toInt(),
            wastedBytes: (g['wastedBytes'] as num).toInt(),
            files: ((g['files'] as List).cast<Map<String, dynamic>>())
                .map((m) => DuplicateFile(
                      id: m['id'] as String,
                      parentId: m['parentId'] as String,
                      name: m['name'] as String,
                      modifiedAt:
                          DateTime.parse(m['modifiedAt'] as String),
                    ))
                .toList(),
          )
      ];
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> downloadArchiveToFile(
    String folderId,
    String destPath, {
    void Function(int received, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.get<ResponseBody>(
        '/files/$folderId/archive',
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
      final file = File(destPath);
      final sink = file.openWrite();
      var received = 0;
      final total =
          int.tryParse(response.headers.value('content-length') ?? '');
      await for (final chunk in response.data!.stream) {
        if (cancelToken?.isCancelled == true) break;
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> setFavorite(String id, bool value) async {
    try {
      final response =
          await _dio.patch('/files/$id', data: {'isFavorite': value});
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<VaultFile>> listFavorites() async {
    try {
      final response = await _dio.get('/files/favorites');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<VaultFile>> listRecent({int limit = 30}) async {
    try {
      final response =
          await _dio.get('/files/recent', queryParameters: {'limit': limit});
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseFile).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> touchOpen(String id) async {
    try {
      final response = await _dio.post('/files/$id/open');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<FileVersion>> listVersions(String fileId) async {
    try {
      final response = await _dio.get('/files/$fileId/versions');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseVersion).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<VaultFile> restoreVersion(String fileId, int version) async {
    try {
      final response =
          await _dio.post('/files/$fileId/versions/$version/restore');
      final data = LocalVaultApi.decodeData(response);
      return _parseFile(data['item'] as Map<String, dynamic>);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<Map<String, int>> storageBreakdown() async {
    try {
      final response = await _dio.get('/storage/breakdown');
      final data = LocalVaultApi.decodeData(response);
      final map = data['breakdown'] as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toInt()));
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<AuditEntry>> activity({int limit = 50}) async {
    try {
      final response =
          await _dio.get('/activity', queryParameters: {'limit': limit});
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseAudit).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  HostSettings _parseSettings(Map<String, dynamic> data) => HostSettings(
        trashRetentionDays: (data['trashRetentionDays'] as num).toInt(),
        deviceQuotaBytes: (data['deviceQuotaBytes'] as num).toInt(),
        tlsConfigured: data['tlsConfigured'] as bool? ?? false,
        shareDefaultExpiryHours:
            (data['shareDefaultExpiryHours'] as num?)?.toInt() ?? 168,
      );

  Future<HostSettings> getSettings() async {
    try {
      final response = await _dio.get('/settings');
      final data = LocalVaultApi.decodeData(response);
      return _parseSettings(data);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<HostSettings> updateSettings({
    int? trashRetentionDays,
    int? deviceQuotaBytes,
    String? tlsCertPath,
    String? tlsKeyPath,
    bool clearTls = false,
  }) async {
    try {
      final response = await _dio.put('/settings', data: {
        if (trashRetentionDays != null)
          'trashRetentionDays': trashRetentionDays,
        if (deviceQuotaBytes != null) 'deviceQuotaBytes': deviceQuotaBytes,
        if (clearTls) ...{'tlsCertPath': '', 'tlsKeyPath': ''},
        if (tlsCertPath != null) 'tlsCertPath': tlsCertPath,
        if (tlsKeyPath != null) 'tlsKeyPath': tlsKeyPath,
      });
      final data = LocalVaultApi.decodeData(response);
      return _parseSettings(data);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<int> purgeExpiredTrash() async {
    try {
      final response = await _dio.post('/trash/purge-expired');
      final data = LocalVaultApi.decodeData(response);
      return (data['purgedBlobs'] as num?)?.toInt() ?? 0;
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<int> syncVersion() async {
    try {
      final response = await _dio.get('/sync/version');
      final data = LocalVaultApi.decodeData(response);
      return (data['version'] as num).toInt();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<({String token, SharedLink link})> createShare({
    required String fileId,
    double? expiresInHours,
    String? password,
    int? maxDownloads,
  }) async {
    try {
      final response = await _dio.post('/shares', data: {
        'fileId': fileId,
        if (expiresInHours != null) 'expiresInHours': expiresInHours,
        if (password != null && password.isNotEmpty) 'password': password,
        if (maxDownloads != null) 'maxDownloads': maxDownloads,
      });
      final data = LocalVaultApi.decodeData(response);
      return (
        token: data['token'] as String,
        link: _parseShare(data['item'] as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<({String token, SharedLink link})> createUploadRequest({
    required String targetFolderId,
    double? expiresInHours,
    String? password,
    int? maxDownloads,
  }) async {
    try {
      final response = await _dio.post('/shares', data: {
        'mode': 'upload',
        'targetFolderId': targetFolderId,
        if (expiresInHours != null) 'expiresInHours': expiresInHours,
        if (password != null && password.isNotEmpty) 'password': password,
        if (maxDownloads != null) 'maxDownloads': maxDownloads,
      });
      final data = LocalVaultApi.decodeData(response);
      return (
        token: data['token'] as String,
        link: _parseShare(data['item'] as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<List<SharedLink>> listShares() async {
    try {
      final response = await _dio.get('/shares');
      final data = LocalVaultApi.decodeData(response);
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      return items.map(_parseShare).toList();
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<void> deleteShare(String tokenPrefix) async {
    try {
      final response = await _dio.delete('/shares/$tokenPrefix');
      LocalVaultApi.decodeData(response);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  Future<Device> createApiToken({required String name, int days = 365}) async {
    try {
      final response = await _dio.post('/devices/token', data: {
        'name': name,
        'days': days,
      });
      final data = LocalVaultApi.decodeData(response);
      // Plaintext tokens come back once; surface via the device note.
      final device = _parseDevice(data['device'] as Map<String, dynamic>);
      _lastApiTokens = (
        access: data['accessToken'] as String,
        refresh: data['refreshToken'] as String,
      );
      return device;
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// Plaintext of the most recently created API token (returned once).
  ({String access, String refresh})? _lastApiTokens;
  ({String access, String refresh})? takeLastApiTokens() {
    final t = _lastApiTokens;
    _lastApiTokens = null;
    return t;
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
    String? replaceFileId,
  }) async {
    try {
      final response = await _dio.post('/files/upload/start', data: {
        'parentId': parentId,
        'name': name,
        'size': size,
        'checksum': checksum,
        if (mime != null) 'mime': mime,
        if (replaceFileId != null) 'replaceFileId': replaceFileId,
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

  /// First bytes of a file for text preview (Range-capped, never the whole
  /// file — safe for large logs/code).
  Future<String> previewText(String fileId, {int maxBytes = 131072}) async {
    try {
      final response = await _dio.get(
        '/files/$fileId/content',
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Range': 'bytes=0-${maxBytes - 1}'},
        ),
      );
      final bytes = (response.data as List).cast<int>();
      // Never throw on binary content; replacement chars are fine.
      return utf8.decode(bytes, allowMalformed: true);
    } on DioException catch (e) {
      throw LocalVaultApi.mapError(e);
    }
  }

  /// True for text/code that renders well in the built-in text preview.
  static bool isTextPreviewable(String name, String? mime) {
    final m = (mime ?? '').toLowerCase();
    if (m.startsWith('text/') ||
        m.contains('json') ||
        m.contains('xml') ||
        m.contains('javascript') ||
        m.contains('yaml')) {
      return true;
    }
    const exts = {
      'txt', 'md', 'csv', 'log', 'json', 'yaml', 'yml', 'xml', 'html',
      'css', 'js', 'ts', 'dart', 'py', 'rs', 'go', 'java', 'kt', 'c',
      'h', 'cpp', 'sh', 'toml', 'ini', 'cfg', 'gradle', 'sql', 'r',
    };
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return exts.contains(ext);
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
        isFavorite: m['isFavorite'] as bool? ?? false,
        lastOpenedAt: m['lastOpenedAt'] == null
            ? null
            : DateTime.parse(m['lastOpenedAt'] as String),
        tags: (m['tags'] as List?)
                ?.map((t) => t.toString())
                .toList() ??
            const [],
      );

  static FileVersion _parseVersion(Map<String, dynamic> m) => FileVersion(
        id: m['id'] as String,
        fileId: m['fileId'] as String,
        version: (m['version'] as num).toInt(),
        blobId: m['blobId'] as String?,
        size: (m['size'] as num).toInt(),
        checksum: m['checksum'] as String?,
        mime: m['mime'] as String?,
        createdAt: DateTime.parse(m['createdAt'] as String),
      );

  static AuditEntry _parseAudit(Map<String, dynamic> m) => AuditEntry(
        id: m['id'] as String,
        deviceId: m['deviceId'] as String?,
        action: m['action'] as String,
        targetId: m['targetId'] as String?,
        targetName: m['targetName'] as String?,
        detail: m['detail'] as String?,
        createdAt: DateTime.parse(m['createdAt'] as String),
      );

  static SharedLink _parseShare(Map<String, dynamic> m) => SharedLink(
        tokenPrefix: m['tokenPrefix'] as String? ?? '',
        fileId: m['fileId'] as String,
        fileName: m['fileName'] as String,
        hasPassword: m['hasPassword'] as bool? ?? false,
        expiresAt: m['expiresAt'] == null
            ? null
            : DateTime.parse(m['expiresAt'] as String),
        createdAt: DateTime.parse(m['createdAt'] as String),
        downloadCount: (m['downloadCount'] as num?)?.toInt() ?? 0,
        mode: m['mode'] as String? ?? 'download',
        maxDownloads: (m['maxDownloads'] as num?)?.toInt(),
      );

  static FileComment _parseComment(Map<String, dynamic> m) => FileComment(
        id: m['id'] as String,
        fileId: m['fileId'] as String,
        author: m['author'] as String? ?? 'owner',
        body: m['body'] as String,
        createdAt: DateTime.parse(m['createdAt'] as String),
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