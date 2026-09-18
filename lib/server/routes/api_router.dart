import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf_multipart/shelf_multipart.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/logging/app_logger.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/file_names.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/audit_entry.dart';
import '../../data/models/device.dart';
import '../../data/models/file_version.dart';
import '../../data/models/vault_file.dart';
import '../middleware/api_responses.dart';
import '../middleware/auth_middleware.dart';
import '../services/pairing_service.dart';
import '../services/token_service.dart';

/// JSON serialization helpers for API models.
Map<String, Object?> fileToJson(VaultFile f) => {
      'id': f.id,
      'parentId': f.parentId,
      'name': f.name,
      'type': f.type,
      'mime': f.mime,
      'size': f.size,
      'checksum': f.checksum,
      'createdAt': f.createdAt.toIso8601String(),
      'modifiedAt': f.modifiedAt.toIso8601String(),
      'deletedAt': f.deletedAt?.toIso8601String(),
      'hasThumb': f.hasThumb,
      'isFavorite': f.isFavorite,
      'lastOpenedAt': f.lastOpenedAt?.toIso8601String(),
    };

Map<String, Object?> versionToJson(FileVersion v) => {
      'id': v.id,
      'fileId': v.fileId,
      'version': v.version,
      'blobId': v.blobId,
      'size': v.size,
      'checksum': v.checksum,
      'mime': v.mime,
      'createdAt': v.createdAt.toIso8601String(),
    };

Map<String, Object?> auditToJson(AuditEntry a) => {
      'id': a.id,
      'deviceId': a.deviceId,
      'action': a.action,
      'targetId': a.targetId,
      'targetName': a.targetName,
      'detail': a.detail,
      'createdAt': a.createdAt.toIso8601String(),
    };

Map<String, Object?> deviceToJson(Device d) => {
      'id': d.id,
      'name': d.name,
      'createdAt': d.createdAt.toIso8601String(),
      'lastSeenAt': d.lastSeenAt?.toIso8601String(),
      'isCurrent': d.isCurrent,
    };

/// All REST route handlers for the LocalVault host server.
class ApiHandlers {
  ApiHandlers(this.vault, this.tokens, this.pairingStore)
      : _loginLimiter =
            RateLimiter(name: 'login', limit: AppConstants.maxLoginAttemptsPerMinute),
        _pairLimiter =
            RateLimiter(name: 'pair', limit: AppConstants.maxPairingAttemptsPerMinute),
        _pairIssueLimiter = RateLimiter(
            name: 'pair-issue', limit: AppConstants.maxPairingIssuesPerMinute);

  final Vault vault;
  final TokenService tokens;
  final PairingCodeStore pairingStore;
  final RateLimiter _loginLimiter;
  final RateLimiter _pairLimiter;
  final RateLimiter _pairIssueLimiter;

  String _clientIp(Request request) {
    final forwarded = request.headers['x-forwarded-for'];
    if (forwarded != null && forwarded.trim().isNotEmpty) {
      return forwarded.split(',').first.trim();
    }
    final ctx = request.context['shelf.io.connection_info'];
    if (ctx is HttpConnectionInfo) {
      return ctx.remoteAddress.address;
    }
    return 'unknown';
  }

  Future<Map<String, Object?>> _jsonBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) return const {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const ValidationException('JSON body must be an object.');
    }
    return decoded;
  }

  // ---------------------------------------------------------------------------
  // Public endpoints
  // ---------------------------------------------------------------------------

  Response health(Request request) {
    return ApiResponses.ok({
      'status': 'ok',
      'app': AppConstants.appName,
      'version': AppConstants.appVersion,
      'serverTime': DateTime.now().toUtc().toIso8601String(),
      'setupComplete': vault.isSetup,
    });
  }

  Future<Response> setup(Request request) async {
    if (vault.isSetup) {
      return ApiResponses.conflict('Host is already set up.');
    }
    final body = await _jsonBody(request);
    final password = body['password']?.toString() ?? '';
    final deviceName = FileNames.sanitize(
        body['deviceName']?.toString().trim() ?? 'Host device');
    await vault.completeSetup(password: password, deviceName: deviceName);
    logInfo('Host setup completed for "$deviceName"');

    final device = tokens.createDevice(
      deviceId: const Uuid().v4(),
      deviceName: deviceName,
      isCurrent: true,
    );
    return ApiResponses.created({
      'device': deviceToJson(vault.devices.getById(device.deviceId)),
      'accessToken': device.accessToken,
      'refreshToken': device.refreshToken,
    });
  }

  Future<Response> login(Request request) async {
    final ip = _clientIp(request);
    if (!_loginLimiter.allow(ip)) {
      return ApiResponses.rateLimited('Too many login attempts. Try again later.');
    }
    if (!vault.isSetup) {
      return ApiResponses.conflict('Host is not set up yet.');
    }
    final body = await _jsonBody(request);
    final password = body['password']?.toString() ?? '';
    final deviceName = FileNames.sanitize(
        body['deviceName']?.toString().trim() ?? 'Client device');

    final ok = await vault.verifyPassword(password);
    if (!ok) {
      return ApiResponses.unauthorized('Invalid password.');
    }
    final existing = vault.devices.findLiveByName(deviceName);
    final device = existing != null
        ? tokens.rotate(existing.id, deviceName)
        : tokens.createDevice(
            deviceId: const Uuid().v4(),
            deviceName: deviceName,
          );
    return ApiResponses.ok({
      'device': deviceToJson(vault.devices.getById(device.deviceId)),
      'accessToken': device.accessToken,
      'refreshToken': device.refreshToken,
    });
  }

  Future<Response> refresh(Request request) async {
    final body = await _jsonBody(request);
    final refreshToken = body['refreshToken']?.toString() ?? '';
    if (refreshToken.isEmpty) {
      return ApiResponses.unauthorized('Missing refresh token.');
    }
    final device = vault.devices
        .findByRefreshTokenHash(Cipher.sha256String(refreshToken));
    if (device == null) {
      return ApiResponses.unauthorized('Refresh token is invalid or expired.');
    }
    final rotated = tokens.rotate(device.id, device.name);
    return ApiResponses.ok({
      'device': deviceToJson(vault.devices.getById(rotated.deviceId)),
      'accessToken': rotated.accessToken,
      'refreshToken': rotated.refreshToken,
    });
  }

  Future<Response> pair(Request request) async {
    final ip = _clientIp(request);
    if (!_pairLimiter.allow(ip)) {
      return ApiResponses.rateLimited('Too many pairing attempts. Try again later.');
    }
    if (!vault.isSetup) {
      return ApiResponses.conflict('Host is not set up yet.');
    }
    final body = await _jsonBody(request);
    final code = body['pairingCode']?.toString() ?? '';
    final deviceName = FileNames.sanitize(
        body['deviceName']?.toString().trim() ?? 'Client device');

    if (pairingStore.consume(code) == null) {
      return ApiResponses.unauthorized('Pairing code is invalid or expired.');
    }
    final existing = vault.devices.findLiveByName(deviceName);
    final device = existing != null
        ? tokens.rotate(existing.id, deviceName)
        : tokens.createDevice(
            deviceId: const Uuid().v4(),
            deviceName: deviceName,
          );
    logInfo('Device paired via code: $deviceName (${device.deviceId})');
    return ApiResponses.ok({
      'device': deviceToJson(vault.devices.getById(device.deviceId)),
      'accessToken': device.accessToken,
      'refreshToken': device.refreshToken,
    });
  }

  // ---------------------------------------------------------------------------
  // Protected endpoints
  // ---------------------------------------------------------------------------

  Future<Response> pairingStart(Request request) async {
    final device = _device(request);
    if (!_pairIssueLimiter.allow(device.id)) {
      return ApiResponses.rateLimited('Too many pairing codes requested.');
    }
    final code = pairingStore.issue(deviceId: device.id);
    return ApiResponses.ok({
      'code': code,
      'expiresInSeconds': AppConstants.pairingCodeLifetime.inSeconds,
      'expiresAt': DateTime.now()
          .add(AppConstants.pairingCodeLifetime)
          .toIso8601String(),
    });
  }

  Future<Response> logout(Request request) async {
    final device = _device(request);
    vault.devices.clearTokens(device.id);
    return ApiResponses.ok();
  }

  Future<Response> listFiles(Request request) async {
    final parentId = request.url.queryParameters['parentId'] ?? AppConstants.rootFolderId;
    final includeTrashed = request.url.queryParameters['includeTrashed'] == 'true';
    vault.files.getById(parentId); // validate existence
    final items = vault.files.listChildren(parentId, includeTrashed: includeTrashed);
    return ApiResponses.ok({
      'parentId': parentId,
      'items': items.map(fileToJson).toList(),
    });
  }

  Future<Response> createFolder(Request request) async {
    final device = _device(request);
    final body = await _jsonBody(request);
    final parentId = body['parentId']?.toString() ?? AppConstants.rootFolderId;
    final name = body['name']?.toString() ?? '';
    final folder = vault.files.createFolder(parentId, name);
    vault.auditAction(
      deviceId: device.id,
      action: 'folder.create',
      targetId: folder.id,
      targetName: folder.name,
    );
    return ApiResponses.created({'item': fileToJson(folder)});
  }

  Future<Response> uploadStart(Request request) async {
    final device = _device(request);
    final body = await _jsonBody(request);
    final parentId = body['parentId']?.toString() ?? AppConstants.rootFolderId;
    final name = body['name']?.toString() ?? '';
    final size = (body['size'] as num?)?.toInt() ?? -1;
    final checksum = body['checksum']?.toString() ?? '';
    final mime = body['mime']?.toString();
    final replaceFileId = body['replaceFileId']?.toString();

    Cipher.validateSha256(checksum);
    if (size < 0) {
      throw const ValidationException('size must be a non-negative integer.');
    }
    final safeName = FileNames.sanitize(name);
    vault.files.requireFolder(parentId);
    if (replaceFileId != null && replaceFileId.isNotEmpty) {
      final target = vault.files.getById(replaceFileId);
      if (target.isTrashed || target.isFolder) {
        throw const ValidationException(
            'Only live files can receive a new version.');
      }
    }
    vault.enforceQuota(size);

    final uploadId = const Uuid().v4();
    final session = vault.uploads.create(
      id: uploadId,
      parentId: parentId,
      name: safeName,
      size: size,
      expectedChecksum: checksum,
      tmpPath: '${AppConstants.tmpDirName}/$uploadId',
      mime: mime,
      deviceId: device.id,
      replaceFileId: (replaceFileId != null && replaceFileId.isNotEmpty)
          ? replaceFileId
          : null,
    );
    return ApiResponses.created({
      'uploadId': session.id,
      'chunkSize': AppConstants.uploadChunkSize,
      'expectedChecksum': session.expectedChecksum,
      'received': session.received,
    });
  }

  Future<Response> uploadChunk(Request request) async {
    final form = FormDataRequest.of(request);
    if (form == null) {
      return ApiResponses.validation('Expected multipart/form-data body.');
    }
    String? uploadId;
    int offset = -1;
    Uint8List? chunk;
    await for (final data in form.formData) {
      switch (data.name) {
        case 'uploadId':
          uploadId = await data.part.readString();
        case 'offset':
          offset = int.tryParse(await data.part.readString()) ?? -1;
        case 'chunk':
          chunk = await data.part.readBytes();
      }
    }
    if (uploadId == null || offset < 0 || chunk == null) {
      return ApiResponses.validation(
          'Missing uploadId, offset or chunk in multipart body.');
    }

    final session = vault.uploads.getById(uploadId);
    if (session.status != UploadSessionStatus.active) {
      return ApiResponses.conflict('Upload session is not active.');
    }
    if (offset != session.received) {
      return ApiResponses.conflict(
          'Unexpected chunk offset $offset, expected ${session.received}.');
    }
    if (session.received + chunk.length > session.size) {
      return ApiResponses.validation('Chunk exceeds declared file size.');
    }

    final file = vault.tmpFile(session.id);
    final raf = await file.open(mode: FileMode.write);
    try {
      await raf.setPosition(offset);
      await raf.writeFrom(chunk);
    } finally {
      await raf.close();
    }
    final updated = vault.uploads.appendChunk(session.id, offset + chunk.length);
    return ApiResponses.ok({'uploadId': session.id, 'received': updated.received});
  }

  Future<Response> uploadStatus(Request request) async {
    final body = await _jsonBody(request);
    final uploadId = body['uploadId']?.toString() ?? '';
    final session = vault.uploads.getById(uploadId);
    return ApiResponses.ok({
      'uploadId': session.id,
      'received': session.received,
      'size': session.size,
      'status': session.status,
    });
  }

  Future<Response> uploadComplete(Request request) async {
    final body = await _jsonBody(request);
    final uploadId = body['uploadId']?.toString() ?? '';
    final session = vault.uploads.getById(uploadId);
    if (session.status != UploadSessionStatus.active) {
      return ApiResponses.conflict('Upload session is not active.');
    }
    if (session.received != session.size) {
      return ApiResponses.validation(
          'Upload incomplete: received ${session.received} of ${session.size} bytes.');
    }
    final tmpFile = vault.tmpFile(session.id);
    if (!await tmpFile.exists()) {
      throw const StorageException('Uploaded data is missing on disk.');
    }

    final actualChecksum = await Cipher.sha256File(tmpFile);
    if (actualChecksum != session.expectedChecksum) {
      logWarn('Checksum mismatch for upload ${session.id}: expected '
          '${session.expectedChecksum}, got $actualChecksum');
      vault.uploads.setStatus(session.id, UploadSessionStatus.aborted);
      await tmpFile.delete().catchError((_) => tmpFile);
      return ApiResponses.error(422, 'CHECKSUM_MISMATCH',
          'Checksum verification failed. Upload rejected and cleaned up.');
    }

    final blob = await vault.storeBlob(
      sourcePath: tmpFile.path,
      size: session.size,
      checksum: session.expectedChecksum,
      mimeType: session.mime,
    );
    vault.uploads.setStatus(session.id, UploadSessionStatus.completed);
    await tmpFile.delete().catchError((_) => tmpFile);

    // Replace-upload: archive previous content, then point at the new blob.
    if (session.replaceFileId != null) {
      final target = vault.files.getById(session.replaceFileId!);
      vault.versions.snapshot(
        fileId: target.id,
        blobId: target.blobId,
        size: target.size,
        checksum: target.checksum,
        mime: target.mime,
      );
      final updated = vault.files.replaceContent(
        id: target.id,
        blobId: blob.id,
        size: session.size,
        checksum: session.expectedChecksum,
        mime: session.mime,
      );
      unawaited(vault.generateThumbnail(updated));
      vault.auditAction(
        action: 'file.version.create',
        targetId: updated.id,
        targetName: updated.name,
      );
      return ApiResponses.created({'item': fileToJson(updated)});
    }

    final file = vault.files.createFile(
      parentId: session.parentId,
      name: session.name,
      size: session.size,
      checksum: session.expectedChecksum,
      blobId: blob.id,
      mime: session.mime,
    );
    // Fire and forget thumbnail generation; failures are logged, not fatal.
    unawaited(vault.generateThumbnail(file));
    vault.auditAction(
      action: 'file.upload',
      targetId: file.id,
      targetName: file.name,
    );
    return ApiResponses.created({'item': fileToJson(file)});
  }

  Future<Response> download(Request request, String id) async {
    final file = vault.files.getById(id);
    if (file.isTrashed) throw const NotFoundException('Item is in the trash.');
    if (file.isFolder) {
      return ApiResponses.validation('Cannot download a folder.');
    }
    if (file.blobId == null) {
      throw const NotFoundException('File has no content.');
    }
    final blob = vault.blobs.getById(file.blobId!);
    final diskFile = vault.blobFile(blob);
    if (!await diskFile.exists()) {
      throw const StorageException('File bytes are missing on disk.');
    }
    final length = await diskFile.length();
    final range = request.headers['range'];
    return _rangedResponse(diskFile, length, file.mime, file.name, range);
  }

  Future<Response> thumb(Request request, String id) async {
    final file = vault.files.getById(id);
    if (file.isTrashed || !file.hasThumb) {
      throw const NotFoundException('No thumbnail available.');
    }
    final thumbFile = vault.thumbFile(file.id);
    if (!await thumbFile.exists()) {
      throw const NotFoundException('No thumbnail available.');
    }
    final bytes = await thumbFile.readAsBytes();
    return Response.ok(bytes, headers: {
      'content-type': 'image/png',
      'content-length': '${bytes.length}',
      'cache-control': 'public, max-age=86400',
    });
  }

  Future<Response> update(Request request, String id) async {
    final device = _device(request);
    final body = await _jsonBody(request);
    var entry = vault.files.getById(id);
    if (entry.isTrashed) {
      throw const ValidationException('Trashed items cannot be updated.');
    }
    if (body.containsKey('name')) {
      final name = body['name']?.toString() ?? '';
      final before = entry.name;
      entry = vault.files.rename(id, name);
      vault.auditAction(
        deviceId: device.id,
        action: 'file.rename',
        targetId: id,
        targetName: entry.name,
        detail: '$before -> ${entry.name}',
      );
    }
    if (body.containsKey('parentId')) {
      final parentId = body['parentId']?.toString() ?? '';
      entry = vault.files.move(id, parentId);
      vault.auditAction(
        deviceId: device.id,
        action: 'file.move',
        targetId: id,
        targetName: entry.name,
      );
    }
    if (body.containsKey('isFavorite')) {
      final raw = body['isFavorite'];
      final value = raw == true || raw == 1 || raw == '1' || raw == 'true';
      entry = vault.files.setFavorite(id, value);
      vault.auditAction(
        deviceId: device.id,
        action: value ? 'file.star' : 'file.unstar',
        targetId: id,
        targetName: entry.name,
      );
    }
    return ApiResponses.ok({'item': fileToJson(entry)});
  }

  Future<Response> delete(Request request, String id) async {
    final device = _device(request);
    String? name;
    try {
      name = vault.files.getById(id).name;
    } catch (_) {}
    vault.files.softDelete(id);
    vault.auditAction(
      deviceId: device.id,
      action: 'file.trash',
      targetId: id,
      targetName: name,
    );
    return ApiResponses.ok();
  }

  Future<Response> listFavorites(Request request) async {
    final items = vault.files.listFavorites();
    return ApiResponses.ok({'items': items.map(fileToJson).toList()});
  }

  Future<Response> listRecent(Request request) async {
    final limit =
        int.tryParse(request.url.queryParameters['limit'] ?? '30') ?? 30;
    final items = vault.files.listRecent(limit: limit);
    return ApiResponses.ok({'items': items.map(fileToJson).toList()});
  }

  Future<Response> touchOpen(Request request, String id) async {
    final entry = vault.files.getById(id);
    if (entry.isTrashed) throw const NotFoundException('Item is in the trash.');
    vault.files.touchOpened(id);
    return ApiResponses.ok({'item': fileToJson(vault.files.getById(id))});
  }

  Future<Response> listVersions(Request request, String id) async {
    vault.files.getById(id); // validate existence
    final versions = vault.versions.listForFile(id);
    return ApiResponses.ok({
      'fileId': id,
      'items': versions.map(versionToJson).toList(),
    });
  }

  Future<Response> restoreVersion(Request request, String id, String version) async {
    final device = _device(request);
    final v = int.tryParse(version);
    if (v == null) return ApiResponses.validation('Invalid version number.');
    final current = vault.files.getById(id);
    if (current.isTrashed || current.isFolder) {
      throw const ValidationException('Only live files can be restored.');
    }
    final archived = vault.versions.getVersion(id, v);
    if (archived == null) throw const NotFoundException('Version not found.');
    if (archived.blobId == null) {
      throw const NotFoundException('Version has no content.');
    }
    try {
      vault.blobs.getById(archived.blobId!);
    } catch (_) {
      throw const NotFoundException('Version bytes are gone.');
    }
    // Snapshot current content first so restore stays reversible.
    vault.versions.snapshot(
      fileId: id,
      blobId: current.blobId,
      size: current.size,
      checksum: current.checksum,
      mime: current.mime,
    );
    final updated = vault.files.replaceContent(
      id: id,
      blobId: archived.blobId!,
      size: archived.size,
      checksum: archived.checksum ?? '',
      mime: archived.mime,
    );
    unawaited(vault.generateThumbnail(updated));
    vault.auditAction(
      deviceId: device.id,
      action: 'file.version.restore',
      targetId: id,
      targetName: updated.name,
      detail: 'v$v',
    );
    return ApiResponses.ok({'item': fileToJson(updated)});
  }

  Future<Response> storageBreakdown(Request request) async {
    final map = vault.files.breakdown();
    return ApiResponses.ok({'breakdown': map});
  }

  Future<Response> activity(Request request) async {
    final limit =
        int.tryParse(request.url.queryParameters['limit'] ?? '50') ?? 50;
    final items = vault.audit.recent(limit: limit);
    return ApiResponses.ok({'items': items.map(auditToJson).toList()});
  }

  Future<Response> getSettings(Request request) async {
    return ApiResponses.ok({
      'trashRetentionDays': vault.settings.trashRetentionDays,
      'deviceQuotaBytes': vault.settings.deviceQuotaBytes,
      'tlsConfigured':
          (vault.settings.tlsCertPath ?? '').isNotEmpty &&
              (vault.settings.tlsKeyPath ?? '').isNotEmpty,
    });
  }

  Future<Response> updateSettings(Request request) async {
    final device = _device(request);
    final body = await _jsonBody(request);
    if (body.containsKey('trashRetentionDays')) {
      final days = (body['trashRetentionDays'] as num?)?.toInt();
      if (days == null || days < 0 || days > 3650) {
        return ApiResponses.validation(
            'trashRetentionDays must be 0..3650.');
      }
      vault.settings.trashRetentionDays = days;
    }
    if (body.containsKey('deviceQuotaBytes')) {
      final quota = (body['deviceQuotaBytes'] as num?)?.toInt();
      if (quota == null || quota < 0) {
        return ApiResponses.validation('deviceQuotaBytes must be >= 0.');
      }
      vault.settings.deviceQuotaBytes = quota;
    }
    if (body.containsKey('tlsCertPath') || body.containsKey('tlsKeyPath')) {
      final cert = body['tlsCertPath']?.toString() ?? '';
      final key = body['tlsKeyPath']?.toString() ?? '';
      if (cert.isEmpty && key.isEmpty) {
        vault.settings.tlsPaths = null;
      } else {
        if (cert.isEmpty || key.isEmpty) {
          return ApiResponses.validation(
              'Both tlsCertPath and tlsKeyPath are required.');
        }
        if (!await File(cert).exists() || !await File(key).exists()) {
          return ApiResponses.validation('TLS cert/key files not found.');
        }
        vault.settings.tlsPaths = (cert: cert, key: key);
      }
    }
    vault.auditAction(deviceId: device.id, action: 'settings.update');
    return ApiResponses.ok({
      'trashRetentionDays': vault.settings.trashRetentionDays,
      'deviceQuotaBytes': vault.settings.deviceQuotaBytes,
      'tlsConfigured':
          (vault.settings.tlsCertPath ?? '').isNotEmpty &&
              (vault.settings.tlsKeyPath ?? '').isNotEmpty,
    });
  }

  Future<Response> purgeExpiredTrash(Request request) async {
    final device = _device(request);
    final orphans = await _purgeExpired();
    vault.auditAction(
      deviceId: device.id,
      action: 'trash.purge.manual',
      detail: '${orphans.length} blob(s)',
    );
    return ApiResponses.ok({'purgedBlobs': orphans.length});
  }

  Future<List<Object>> _purgeExpired() async {
    final days = vault.settings.trashRetentionDays;
    if (days <= 0) return const [];
    final cutoff = DateTime.now().subtract(Duration(days: days));
    final orphans = vault.files.purgeTrashOlderThan(cutoff, vault.blobs);
    await vault.deleteOrphanedBlobs(orphans);
    return orphans;
  }

  Future<Response> search(Request request) async {
    final q = request.url.queryParameters['q']?.trim() ?? '';
    if (q.isEmpty) {
      return ApiResponses.ok({'items': <Object?>[]});
    }
    final items = vault.files.search(q);
    return ApiResponses.ok({
      'query': q,
      'items': items.map(fileToJson).toList(),
    });
  }

  Future<Response> listTrash(Request request) async {
    final items = vault.files.listTrash();
    return ApiResponses.ok({'items': items.map(fileToJson).toList()});
  }

  Future<Response> restore(Request request, String id) async {
    final device = _device(request);
    final restored = vault.files.restore(id);
    vault.auditAction(
      deviceId: device.id,
      action: 'file.restore',
      targetId: id,
      targetName: restored.name,
    );
    return ApiResponses.ok({'item': fileToJson(restored)});
  }

  Future<Response> deletePermanent(Request request, String id) async {
    final device = _device(request);
    String? name;
    try {
      name = vault.files.getById(id).name;
    } catch (_) {}
    final orphans = vault.files.permanentDelete(id, vault.blobs);
    await vault.deleteOrphanedBlobs(orphans);
    vault.versions.deleteForFile(id);
    vault.auditAction(
      deviceId: device.id,
      action: 'file.destroy',
      targetId: id,
      targetName: name,
    );
    return ApiResponses.ok();
  }

  Future<Response> emptyTrash(Request request) async {
    final device = _device(request);
    final orphans = vault.files.emptyTrash(vault.blobs);
    await vault.deleteOrphanedBlobs(orphans);
    vault.auditAction(deviceId: device.id, action: 'trash.empty');
    return ApiResponses.ok();
  }

  Future<Response> storageStatus(Request request) async {
    final status = await vault.storageStatus();
    return ApiResponses.ok({
      'total': status.total,
      'free': status.free,
      'used': status.used,
      'vaultUsage': status.vaultUsage,
      'trashUsage': status.trashUsage,
    });
  }

  Future<Response> devices(Request request) async {
    final list = vault.devices.listAll();
    return ApiResponses.ok({
      'items': list.map(deviceToJson).toList(),
    });
  }

  Future<Response> revokeDevice(Request request, String id) async {
    final device = _device(request);
    vault.devices.revoke(id);
    vault.auditAction(
      deviceId: device.id,
      action: 'device.revoke',
      targetId: id,
    );
    return ApiResponses.ok();
  }

  Device _device(Request request) =>
      request.context['device'] as Device;

  static Response _rangedResponse(
    File file,
    int length,
    String? mimeType,
    String name,
    String? rangeHeader,
  ) {
    const baseHeaders = {
      'accept-ranges': 'bytes',
      'content-type': 'application/octet-stream',
    };
    final headers = Map<String, Object>.of(baseHeaders);
    final mime = mimeType ?? 'application/octet-stream';
    headers['content-type'] = mime;
    headers['content-disposition'] = 'attachment; filename="${_escape(name)}"';

    if (rangeHeader == null || rangeHeader.isEmpty) {
      headers['content-length'] = '$length';
      return Response(200,
          body: file.openRead(), headers: headers);
    }

    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rangeHeader.trim());
    if (match == null) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }
    int? start = match.group(1)!.isEmpty ? null : int.tryParse(match.group(1)!);
    int? end = match.group(2)!.isEmpty ? null : int.tryParse(match.group(2)!);

    if (start == null && end == null) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }
    if (start == null) {
      // suffix range: last N bytes
      final suffix = end!;
      if (suffix <= 0) {
        headers['content-range'] = 'bytes */$length';
        return Response(416, headers: headers, body: '');
      }
      start = (length - suffix).clamp(0, length);
      end = length - 1;
    }
    if (end == null || end >= length) {
      end = length - 1;
    }
    if (start > end || start >= length) {
      headers['content-range'] = 'bytes */$length';
      return Response(416, headers: headers, body: '');
    }

    headers['content-range'] = 'bytes $start-$end/$length';
    headers['content-length'] = '${end - start + 1}';
    return Response(206,
        body: file.openRead(start, end + 1), headers: headers);
  }

  static String _escape(String value) => value
      .replaceAll('"', r'\"')
      .replaceAll('\n', '')
      .replaceAll('\r', '');
}

/// A small constant for upload session status values.
abstract class UploadSessionStatus {
  static const String active = 'active';
  static const String completed = 'completed';
  static const String aborted = 'aborted';
}

/// Builds the full shelf handler for the host server.
Handler buildApiHandler({
  required Vault vault,
  required TokenService tokenService,
  required AuthMiddleware auth,
  required PairingCodeStore pairingStore,
}) {
  final handlers = ApiHandlers(vault, tokenService, pairingStore);

  final publicRouter = Router()
    ..get('/health', handlers.health)
    ..post('/api/v1/setup', handlers.setup)
    ..post('/api/v1/auth/login', handlers.login)
    ..post('/api/v1/auth/refresh', handlers.refresh)
    ..post('/api/v1/pair', handlers.pair);

  final protectedRouter = Router()
    ..post('/api/v1/auth/logout', handlers.logout)
    ..post('/api/v1/pairing/start', handlers.pairingStart)
    ..get('/api/v1/files', handlers.listFiles)
    ..get('/api/v1/files/favorites', handlers.listFavorites)
    ..get('/api/v1/files/recent', handlers.listRecent)
    ..post('/api/v1/files/folder', handlers.createFolder)
    ..post('/api/v1/files/upload/start', handlers.uploadStart)
    ..post('/api/v1/files/upload/chunk', handlers.uploadChunk)
    ..post('/api/v1/files/upload/complete', handlers.uploadComplete)
    ..post('/api/v1/files/upload/status', handlers.uploadStatus)
    ..get('/api/v1/files/<id>/content', handlers.download)
    ..get('/api/v1/files/<id>/thumb', handlers.thumb)
    ..post('/api/v1/files/<id>/open', handlers.touchOpen)
    ..get('/api/v1/files/<id>/versions', handlers.listVersions)
    ..post('/api/v1/files/<id>/versions/<version>/restore',
        handlers.restoreVersion)
    ..patch('/api/v1/files/<id>', handlers.update)
    ..delete('/api/v1/files/<id>', handlers.delete)
    ..get('/api/v1/search', handlers.search)
    ..get('/api/v1/trash', handlers.listTrash)
    ..post('/api/v1/trash/<id>/restore', handlers.restore)
    ..delete('/api/v1/trash/<id>', handlers.deletePermanent)
    ..delete('/api/v1/trash', handlers.emptyTrash)
    ..post('/api/v1/trash/purge-expired', handlers.purgeExpiredTrash)
    ..get('/api/v1/storage/status', handlers.storageStatus)
    ..get('/api/v1/storage/breakdown', handlers.storageBreakdown)
    ..get('/api/v1/activity', handlers.activity)
    ..get('/api/v1/settings', handlers.getSettings)
    ..put('/api/v1/settings', handlers.updateSettings)
    ..get('/api/v1/devices', handlers.devices)
    ..post('/api/v1/devices/<id>/revoke', handlers.revokeDevice);

  final publicPipeline =
      const Pipeline().addMiddleware(errorHandler()).addHandler(publicRouter.call);
  final protectedPipeline = const Pipeline()
      .addMiddleware(errorHandler())
      .addMiddleware(auth.requireAuth())
      .addHandler(protectedRouter.call);

  return Cascade()
      .add(publicPipeline)
      .add(protectedPipeline)
      .add((Request _) async => Response.notFound('Not found.'))
      .handler;
}