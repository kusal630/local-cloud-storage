import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/errors/app_exceptions.dart';
import '../../core/utils/cipher.dart';
import '../../core/utils/file_names.dart';
import '../../data/datasources/vault.dart';
import '../../data/models/vault_file.dart';
import '../middleware/api_responses.dart';

/// Minimal WebDAV endpoint (`/dav/*`) so the cloud mounts as a network
/// drive in Windows Explorer, macOS Finder, Linux file managers, and any
/// WebDAV client.
///
/// Auth is HTTP Basic against the owner username + password (separate from
/// the token API the app uses). Supported: OPTIONS, PROPFIND (depth 0/1),
/// GET (ranges), PUT (create/replace with versioning), MKCOL, DELETE
/// (trash), MOVE, COPY, LOCK/UNLOCK (exclusive write locks, in-memory).
class WebDavHandlers {
  WebDavHandlers(this.vault);

  final Vault vault;

  /// In-memory write locks: fileId → (token, expiresAt).
  final Map<String, ({String token, DateTime expiresAt})> _locks = {};

  // ---------------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------------

  Future<bool> _checkAuth(Request request) async {
    final header = request.headers['authorization'];
    if (header == null || !header.startsWith('Basic ')) return false;
    try {
      final decoded =
          utf8.decode(base64.decode(header.substring(6).trim()));
      final split = decoded.indexOf(':');
      if (split < 0) return false;
      final user = decoded.substring(0, split);
      final pass = decoded.substring(split + 1);
      if (user.isEmpty ||
          user.toLowerCase() != vault.settings.ownerUsername.toLowerCase()) {
        return false;
      }
      return await vault.verifyPassword(pass);
    } catch (_) {
      return false;
    }
  }

  Response _unauthorized() => Response(
        401,
        body: 'Unauthorized.',
        headers: {
          'www-authenticate': 'Basic realm="LocalVault"',
          'content-type': 'text/plain',
        },
      );

  // ---------------------------------------------------------------------------
  // Path mapping: /dav/a/b/c.txt → vault entries
  // ---------------------------------------------------------------------------

  List<String> _segments(Request request) {
    final path = request.url.path;
    if (path == 'dav' || path == 'dav/') return const [];
    final withoutPrefix =
        path.startsWith('dav/') ? path.substring(4) : path;
    return withoutPrefix
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.decodeComponent)
        .toList();
  }

  /// Resolves all segments except the last; returns the parent folder id.
  String _resolveParent(List<String> segments) {
    var current = AppConstants.rootFolderId;
    for (final seg in segments) {
      final children = vault.files.listChildren(current);
      final match = children.where(
          (f) => f.isFolder && !f.isTrashed && f.name == seg);
      if (match.isEmpty) {
        throw const NotFoundException('Path not found.');
      }
      current = match.first.id;
    }
    return current;
  }

  VaultFile? _resolve(List<String> segments) {
    if (segments.isEmpty) return vault.files.getById(AppConstants.rootFolderId);
    final parentId = _resolveParent(segments.sublist(0, segments.length - 1));
    final leaf = segments.last;
    final children = vault.files.listChildren(parentId);
    for (final child in children) {
      if (!child.isTrashed && child.name == leaf) return child;
    }
    return null;
  }

  String _href(List<String> segments, bool collection) {
    final encoded = segments.map(Uri.encodeComponent).join('/');
    final path = encoded.isEmpty ? '/dav/' : '/dav/$encoded${collection ? '/' : ''}';
    return path;
  }

  bool _locked(String fileId, Request request) {
    final lock = _locks[fileId];
    if (lock == null) return false;
    if (lock.expiresAt.isBefore(DateTime.now())) {
      _locks.remove(fileId);
      return false;
    }
    final token = _tokenFromIf(request);
    return token == null || token != lock.token;
  }

  String? _tokenFromIf(Request request) {
    final header = request.headers['if'];
    if (header == null) return null;
    final match = RegExp(r'opaquelocktoken:([^\s>)]+)').firstMatch(header);
    return match?.group(1);
  }

  // ---------------------------------------------------------------------------
  // Methods
  // ---------------------------------------------------------------------------

  Future<Response> options(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    return Response.ok('', headers: {
      'allow':
          'OPTIONS, PROPFIND, GET, PUT, MKCOL, DELETE, MOVE, COPY, LOCK, UNLOCK',
      'dav': '1',
    });
  }

  Future<Response> propfind(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    final depth = (request.headers['depth'] ?? 'infinity').trim();
    if (depth != '0' && depth != '1' && depth != 'infinity') {
      return Response(400, body: 'Unsupported Depth.');
    }
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null || entry.isTrashed) {
      return Response.notFound('Not found.');
    }
    final effectiveDepth = depth == '0' ? 0 : 1;
    final responses = <String>[
      _responseXml(segments, entry, isCollection: entry.isFolder)
    ];
    if (effectiveDepth == 1 && entry.isFolder) {
      for (final child
          in vault.files.listChildren(entry.id)) {
        if (child.isTrashed) continue;
        responses.add(_responseXml([...segments, child.name], child,
            isCollection: child.isFolder));
      }
    }
    final body = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
${responses.join('\n')}
</D:multistatus>''';
    return Response(207,
        body: body,
        headers: {'content-type': 'application/xml; charset=utf-8'});
  }

  String _responseXml(
      List<String> segments, VaultFile entry, {required bool isCollection}) {
    final esc = _xml(entry.name);
    final href = _xml(_href(segments, isCollection));
    final modified = HttpDate.format(entry.modifiedAt.toUtc());
    final created = entry.createdAt.toUtc().toIso8601String();
    final size = isCollection ? '' : '<D:getcontentlength>${entry.size}</D:getcontentlength>';
    final mime = isCollection
        ? ''
        : '<D:getcontenttype>${_xml(entry.mime ?? 'application/octet-stream')}</D:getcontenttype>';
    final etag = entry.checksum == null
        ? ''
        : '<D:getetag>"${entry.checksum}"</D:getetag>';
    final resourcetype = isCollection
        ? '<D:resourcetype><D:collection/></D:resourcetype>'
        : '<D:resourcetype/>';
    return '''  <D:response>
    <D:href>$href</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>$esc</D:displayname>
        $size
        $mime
        <D:getlastmodified>$modified</D:getlastmodified>
        <D:creationdate>$created</D:creationdate>
        $etag
        $resourcetype
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>''';
  }

  Future<Response> get(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null || entry.isTrashed || entry.isFolder) {
      return Response.notFound('Not found.');
    }
    if (entry.blobId == null) {
      throw const NotFoundException('File has no content.');
    }
    final blob = vault.blobs.getById(entry.blobId!);
    final diskFile = vault.blobFile(blob);
    if (!await diskFile.exists()) {
      throw const StorageException('File bytes are missing on disk.');
    }
    final length = await diskFile.length();
    return ApiResponses.rangedFile(
      diskFile,
      length,
      entry.mime,
      entry.name,
      request.headers['range'],
      attachment: false,
    );
  }

  Future<Response> put(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    if (segments.isEmpty) {
      return Response(405, body: 'Cannot PUT a collection.');
    }
    String parentId;
    try {
      parentId = _resolveParent(segments.sublist(0, segments.length - 1));
    } catch (_) {
      return Response(409, body: 'Parent collection missing.');
    }
    final name = FileNames.sanitize(segments.last);
    // Stream the body straight to tmp (never whole in memory).
    const cap = 500 * 1024 * 1024;
    final tmp = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}lv_dav_${const Uuid().v4()}');
    var received = 0;
    try {
      final sink = tmp.openWrite();
      await for (final chunk in request.read()) {
        received += chunk.length;
        if (received > cap) {
          await sink.close();
          await tmp.delete().catchError((_) => tmp);
          return ApiResponses.validation('File exceeds the 500 MB limit.');
        }
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await tmp.delete().catchError((_) => tmp);
      rethrow;
    }
    final checksum = await Cipher.sha256File(tmp);
    vault.enforceQuota(received);
    final existing = _resolve(segments);
    if (existing != null && !existing.isTrashed) {
      if (_locked(existing.id, request)) {
        await tmp.delete().catchError((_) => tmp);
        return Response(423, body: 'Locked.');
      }
      final blob = await vault.storeBlob(
        sourcePath: tmp.path,
        size: received,
        checksum: checksum,
        mimeType: null,
      );
      await tmp.delete().catchError((_) => tmp);
      vault.versions.snapshot(
        fileId: existing.id,
        blobId: existing.blobId,
        size: existing.size,
        checksum: existing.checksum,
        mime: existing.mime,
      );
      vault.files.replaceContent(
        id: existing.id,
        blobId: blob.id,
        size: received,
        checksum: checksum,
      );
      vault.mutated(action: 'file.version.create', targetId: existing.id);
      return Response(204);
    }
    final blob = await vault.storeBlob(
      sourcePath: tmp.path,
      size: received,
      checksum: checksum,
      mimeType: null,
    );
    await tmp.delete().catchError((_) => tmp);
    final created = vault.files.createFile(
      parentId: parentId,
      name: name,
      size: received,
      checksum: checksum,
      blobId: blob.id,
    );
    unawaited(vault.indexTextFile(created.id));
    vault.mutated(
        action: 'file.upload',
        targetId: created.id,
        targetName: created.name);
    return Response(201);
  }

  Future<Response> mkcol(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    if (segments.isEmpty) {
      return Response(405, body: 'Collection exists.');
    }
    String parentId;
    try {
      parentId = _resolveParent(segments.sublist(0, segments.length - 1));
    } catch (_) {
      return Response(409, body: 'Parent collection missing.');
    }
    if (_resolve(segments) != null) {
      return Response(405, body: 'Already exists.');
    }
    final folder =
        vault.files.createFolder(parentId, FileNames.sanitize(segments.last));
    vault.mutated(
        action: 'folder.create',
        targetId: folder.id,
        targetName: folder.name);
    return Response(201);
  }

  Future<Response> delete(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null || entry.isTrashed || entry.id == AppConstants.rootFolderId) {
      return Response.notFound('Not found.');
    }
    if (_locked(entry.id, request)) {
      return Response(423, body: 'Locked.');
    }
    vault.files.softDelete(entry.id);
    vault.mutated(
        action: 'file.trash', targetId: entry.id, targetName: entry.name);
    return Response(204);
  }

  Future<Response> move(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    return _relocate(request, copy: false);
  }

  Future<Response> copy(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    return _relocate(request, copy: true);
  }

  Future<Response> _relocate(Request request, {required bool copy}) async {
    final segments = _segments(request);
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null ||
        entry.isTrashed ||
        entry.id == AppConstants.rootFolderId) {
      return Response.notFound('Not found.');
    }
    final dest = request.headers['destination'];
    if (dest == null || dest.isEmpty) {
      return Response(400, body: 'Destination header required.');
    }
    final destPath = Uri.tryParse(dest)?.path ?? dest;
    final destSegments = destPath.startsWith('/dav/')
        ? destPath
            .substring(5)
            .split('/')
            .where((s) => s.isNotEmpty)
            .map(Uri.decodeComponent)
            .toList()
        : null;
    if (destSegments == null || destSegments.isEmpty) {
      return Response(400, body: 'Destination must be a /dav/ path.');
    }
    String destParent;
    try {
      destParent =
          _resolveParent(destSegments.sublist(0, destSegments.length - 1));
    } catch (_) {
      return Response(409, body: 'Destination parent missing.');
    }
    final overwrite =
        (request.headers['overwrite'] ?? 'T').toUpperCase() != 'F';
    final destName = FileNames.sanitize(destSegments.last);
    VaultFile? clash;
    try {
      final siblings = vault.files.listChildren(destParent);
      for (final s in siblings) {
        if (!s.isTrashed && s.name == destName) clash = s;
      }
    } catch (_) {}
    if (clash != null && !overwrite) {
      return Response(412, body: 'Destination exists.');
    }
    if (!copy && _locked(entry.id, request)) {
      return Response(423, body: 'Locked.');
    }
    var existed = false;
    if (clash != null) {
      existed = true;
      vault.files.softDelete(clash.id);
    }
    VaultFile result;
    if (copy) {
      result = vault.files.copyItem(entry.id, destParent);
      if (result.name != destName) {
        result = vault.files.rename(result.id, destName);
      }
      vault.mutated(
          action: 'file.copy', targetId: result.id, targetName: result.name);
    } else {
      result = vault.files.move(entry.id, destParent);
      if (result.name != destName) {
        result = vault.files.rename(result.id, destName);
      }
      vault.mutated(
          action: 'file.move', targetId: result.id, targetName: result.name);
    }
    return Response(existed ? 204 : 201);
  }

  Future<Response> lock(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null || entry.isTrashed) {
      return Response.notFound('Not found.');
    }
    var seconds = 3600;
    final timeout = request.headers['timeout'] ?? '';
    final match = RegExp(r'Second-(\d+)').firstMatch(timeout);
    if (match != null) {
      seconds = (int.tryParse(match.group(1)!) ?? 3600).clamp(60, 86400);
    }
    final token = 'lv-${const Uuid().v4()}';
    _locks[entry.id] = (
      token: token,
      expiresAt: DateTime.now().add(Duration(seconds: seconds)),
    );
    final body = '''<?xml version="1.0" encoding="utf-8"?>
<D:prop xmlns:D="DAV:">
  <D:lockdiscovery>
    <D:activelock>
      <D:locktype><D:write/></D:locktype>
      <D:lockscope><D:exclusive/></D:lockscope>
      <D:depth>0</D:depth>
      <D:owner>LocalVault</D:owner>
      <D:timeout>Second-$seconds</D:timeout>
      <D:locktoken><D:href>opaquelocktoken:$token</D:href></D:locktoken>
    </D:activelock>
  </D:lockdiscovery>
</D:prop>''';
    return Response(200,
        body: body,
        headers: {
          'content-type': 'application/xml; charset=utf-8',
          'lock-token': '<opaquelocktoken:$token>',
        });
  }

  Future<Response> unlock(Request request) async {
    if (!await _checkAuth(request)) return _unauthorized();
    final segments = _segments(request);
    VaultFile? entry;
    try {
      entry = _resolve(segments);
    } catch (_) {
      return Response.notFound('Not found.');
    }
    if (entry == null) return Response.notFound('Not found.');
    final token = request.headers['lock-token'];
    final lock = _locks[entry.id];
    if (lock == null) return Response(409, body: 'Not locked.');
    if (token == null || !token.contains(lock.token)) {
      return Response(403, body: 'Lock token mismatch.');
    }
    _locks.remove(entry.id);
    return Response(204);
  }

  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// Builds the WebDAV handler mounted at `/dav`.
Handler buildWebdavHandler({required Vault vault}) {
  final handlers = WebDavHandlers(vault);
  // Shelf routes custom methods via add() with exact method names.
  final router = Router()
    ..add('OPTIONS', '/dav/<path|.*>', handlers.options)
    ..add('PROPFIND', '/dav/<path|.*>', handlers.propfind)
    ..add('GET', '/dav/<path|.*>', handlers.get)
    ..add('PUT', '/dav/<path|.*>', handlers.put)
    ..add('MKCOL', '/dav/<path|.*>', handlers.mkcol)
    ..add('DELETE', '/dav/<path|.*>', handlers.delete)
    ..add('MOVE', '/dav/<path|.*>', handlers.move)
    ..add('COPY', '/dav/<path|.*>', handlers.copy)
    ..add('LOCK', '/dav/<path|.*>', handlers.lock)
    ..add('UNLOCK', '/dav/<path|.*>', handlers.unlock)
    ..add('OPTIONS', '/dav', handlers.options)
    ..add('PROPFIND', '/dav', handlers.propfind);
  return const Pipeline()
      .addMiddleware(errorHandler())
      .addHandler(router.call);
}
