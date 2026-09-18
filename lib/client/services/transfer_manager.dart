import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart' as mime_pkg;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/logging/app_logger.dart';
import 'file_service.dart';

enum TransferType { upload, download }

enum TransferStatus { queued, running, completed, failed, cancelled }

String _computeChecksum(String filePath) {
  final bytes = File(filePath).readAsBytesSync();
  return sha256.convert(bytes).toString();
}

class TransferTask {
  TransferTask({
    required this.id,
    required this.type,
    required this.name,
    required this.totalBytes,
    this.sourcePath,
    this.parentId,
    this.fileId,
    this.destPath,
    this.mimeType,
    this.uploadId,
    this.checksum,
    this.replaceFileId,
  })  : transferredBytes = 0,
        status = TransferStatus.queued,
        createdAt = DateTime.now();

  final String id;
  final TransferType type;
  final String name;
  final int totalBytes;
  int transferredBytes;
  TransferStatus status;
  String? error;
  String? sourcePath;
  String? parentId;
  String? fileId;
  String? destPath;
  String? mimeType;
  String? uploadId;
  String? checksum;
  String? replaceFileId;
  bool cancelRequested = false;
  final DateTime createdAt;
  DateTime? startedAt;
  double speedBps = 0;
  /// True when a download's SHA-256 was verified against the vault checksum.
  bool verified = false;
  int _lastBytes = 0;
  DateTime? _lastTick;

  Duration? get eta {
    if (status != TransferStatus.running || speedBps <= 0) return null;
    final remaining = totalBytes - transferredBytes;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / speedBps).ceil());
  }

  void markTick(int bytes) {
    final now = DateTime.now();
    startedAt ??= now;
    final last = _lastTick;
    if (last != null) {
      final dt = now.difference(last).inMilliseconds / 1000.0;
      if (dt > 0.05) {
        final inst = (bytes - _lastBytes) / dt;
        speedBps = speedBps <= 0 ? inst : speedBps * 0.7 + inst * 0.3;
        _lastBytes = bytes;
        _lastTick = now;
      }
    } else {
      _lastBytes = bytes;
      _lastTick = now;
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'type': type.name,
        'name': name,
        'totalBytes': totalBytes,
        'transferredBytes': transferredBytes,
        'status': status.name,
        'error': error,
        'sourcePath': sourcePath,
        'parentId': parentId,
        'fileId': fileId,
        'destPath': destPath,
        'mimeType': mimeType,
        'uploadId': uploadId,
        'checksum': checksum,
        'replaceFileId': replaceFileId,
      };

  static TransferTask? fromJson(Map<String, dynamic> m) {
    try {
      final task = TransferTask(
        id: m['id'] as String,
        type: m['type'] == 'download'
            ? TransferType.download
            : TransferType.upload,
        name: m['name'] as String,
        totalBytes: (m['totalBytes'] as num).toInt(),
        sourcePath: m['sourcePath'] as String?,
        parentId: m['parentId'] as String?,
        fileId: m['fileId'] as String?,
        destPath: m['destPath'] as String?,
        mimeType: m['mimeType'] as String?,
        uploadId: m['uploadId'] as String?,
        checksum: m['checksum'] as String?,
        replaceFileId: m['replaceFileId'] as String?,
      );
      task.transferredBytes = (m['transferredBytes'] as num?)?.toInt() ?? 0;
      task.error = m['error'] as String?;
      return task;
    } catch (_) {
      return null;
    }
  }
}

/// Manages upload and download queues with progress reporting.
class TransferManager extends ChangeNotifier {
  TransferManager(this._fileService);

  final FileService _fileService;
  final List<TransferTask> _tasks = [];
  final Map<String, CancelToken> _tokens = {};

  List<TransferTask> get tasks => List.unmodifiable(_tasks);

  List<TransferTask> get active =>
      _tasks.where((t) => t.status == TransferStatus.running).toList();

  List<TransferTask> get queued =>
      _tasks.where((t) => t.status == TransferStatus.queued).toList();

  List<TransferTask> get completed =>
      _tasks.where((t) => t.status == TransferStatus.completed).toList();

  List<TransferTask> get failed =>
      _tasks.where((t) => t.status == TransferStatus.failed).toList();

  static const String _persistKey = 'transfer_queue_v1';
  bool _restored = false;

  /// Rehydrates tasks persisted before an app restart. Anything that was
  /// in-flight becomes retryable-failed instead of vanishing.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_persistKey);
      if (raw == null || raw.isEmpty) return;
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      var added = false;
      for (final m in list) {
        final task = TransferTask.fromJson(m);
        if (task == null) continue;
        if (task.status == TransferStatus.running ||
            task.status == TransferStatus.queued) {
          task.status = TransferStatus.failed;
          task.error = 'Interrupted by app restart — tap retry.';
        }
        // Drop stale references whose source file is gone.
        if (task.type == TransferType.upload &&
            (task.sourcePath == null ||
                !File(task.sourcePath!).existsSync())) {
          continue;
        }
        _tasks.add(task);
        added = true;
      }
      if (added) _changed();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Cap history so prefs stay small.
      final snapshot = _tasks.length > 50
          ? _tasks.sublist(_tasks.length - 50)
          : _tasks;
      await prefs.setString(
        _persistKey,
        jsonEncode(snapshot.map((t) => t.toJson()).toList()),
      );
    } catch (_) {}
  }

  void _changed() {
    _changed();
    unawaited(_persist());
  }

  void enqueueUpload({
    required String sourcePath,
    required String parentId,
    required String name,
    String? replaceFileId,
  }) {
    final file = File(sourcePath);
    final stat = file.statSync();
    final task = TransferTask(
      id: const Uuid().v4(),
      type: TransferType.upload,
      name: name,
      totalBytes: stat.size,
      sourcePath: sourcePath,
      parentId: parentId,
      mimeType: mime_pkg.lookupMimeType(name),
      replaceFileId: replaceFileId,
    );
    _tasks.add(task);
    _changed();
    _startUpload(task);
  }

  void enqueueDownload({
    required String fileId,
    required String name,
    required String destDir,
    required int totalBytes,
    String? checksum,
  }) {
    final task = TransferTask(
      id: const Uuid().v4(),
      type: TransferType.download,
      name: name,
      totalBytes: totalBytes,
      fileId: fileId,
      destPath: p.join(destDir, name),
      checksum: checksum,
    );
    _tasks.add(task);
    _changed();
    _startDownload(task);
  }

  void cancel(String taskId) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx < 0) return;
    final task = _tasks[idx];
    if (task.status != TransferStatus.queued &&
        task.status != TransferStatus.running) {
      return;
    }
    task.cancelRequested = true;
    _tokens[taskId]?.cancel();
    task.status = TransferStatus.cancelled;
    _tokens.remove(taskId);
    _changed();
  }

  void retry(String taskId) {
    final idx = _tasks.indexWhere((t) => t.id == taskId);
    if (idx < 0) return;
    final task = _tasks[idx];
    if (task.status != TransferStatus.failed &&
        task.status != TransferStatus.cancelled) {
      return;
    }
    task.status = TransferStatus.queued;
    task.transferredBytes = 0;
    task.error = null;
    task.cancelRequested = false;
    _changed();
    if (task.type == TransferType.upload) {
      _startUpload(task);
    } else {
      _startDownload(task);
    }
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == TransferStatus.completed);
    _changed();
  }

  void clearAll() {
    _tasks.clear();
    _changed();
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  Future<void> _startUpload(TransferTask task) async {
    final token = CancelToken();
    _tokens[task.id] = token;
    task.status = TransferStatus.running;
    _changed();

    try {
      // 1. Compute SHA-256 of the source file in a background isolate.
      final checksum = await compute(_computeChecksum, task.sourcePath!);
      task.checksum = checksum;

      // 2. Start upload session on the server.
      final startResult = await _fileService.uploadStart(
        parentId: task.parentId!,
        name: task.name,
        size: task.totalBytes,
        checksum: checksum,
        mime: task.mimeType,
        replaceFileId: task.replaceFileId,
      );
      task.uploadId = startResult.uploadId;
      int offset = startResult.received;
      // 3. Upload chunks.
      final file = File(task.sourcePath!);
      while (offset < task.totalBytes && !task.cancelRequested) {
        final end = (offset + AppConstants.uploadChunkSize).clamp(0, task.totalBytes);
        final raf = await file.open(mode: FileMode.read);
        await raf.setPosition(offset);
        final chunkBytes = await raf.read(end - offset);
        await raf.close();
        offset = await _fileService.uploadChunk(
          task.uploadId!,
          offset,
          chunkBytes,
        );
        task.transferredBytes = offset;
        task.markTick(offset);
        _changed();
      }

      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
        _changed();
        return;
      }

      // 4. Complete upload.
      await _fileService.uploadComplete(task.uploadId!);
      task.status = TransferStatus.completed;
      task.transferredBytes = task.totalBytes;
      _changed();
    } catch (e) {
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = e.toString();
        logError('Upload failed: ${task.name}', e);
      }
      _changed();
    } finally {
      _tokens.remove(task.id);
    }
  }

  // ---------------------------------------------------------------------------
  // Download
  // ---------------------------------------------------------------------------

  Future<void> _startDownload(TransferTask task) async {
    final token = CancelToken();
    _tokens[task.id] = token;
    task.status = TransferStatus.running;
    _changed();

    try {
      await _fileService.downloadToFile(
        task.fileId!,
        task.destPath!,
        onProgress: (received, total) {
          task.transferredBytes = received;
          task.markTick(received);
          _changed();
        },
        cancelToken: token,
      );
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.completed;
        task.transferredBytes = task.totalBytes;
        // Verify integrity against the vault checksum when known.
        if (task.checksum != null && task.checksum!.isNotEmpty) {
          try {
            final actual = await compute(_computeChecksum, task.destPath!);
            if (actual == task.checksum) {
              task.verified = true;
            } else {
              task.status = TransferStatus.failed;
              task.error =
                  'Checksum mismatch — download deleted. Retry to fetch again.';
              logError('Download checksum mismatch: ${task.name}', null);
              try {
                await File(task.destPath!).delete();
              } catch (_) {}
            }
          } catch (e) {
            logError('Download verification failed: ${task.name}', e);
          }
        }
      }
      _changed();
    } catch (e) {
      if (task.cancelRequested || (e is DioException && e.type == DioExceptionType.cancel)) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = e.toString();
        logError('Download failed: ${task.name}', e);
      }
      _changed();
    } finally {
      _tokens.remove(task.id);
    }
  }
}