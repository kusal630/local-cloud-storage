import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart' as mime_pkg;
import 'package:path/path.dart' as p;
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
  bool cancelRequested = false;
  final DateTime createdAt;
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

  void enqueueUpload({
    required String sourcePath,
    required String parentId,
    required String name,
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
    );
    _tasks.add(task);
    notifyListeners();
    _startUpload(task);
  }

  void enqueueDownload({
    required String fileId,
    required String name,
    required String destDir,
    required int totalBytes,
  }) {
    final task = TransferTask(
      id: const Uuid().v4(),
      type: TransferType.download,
      name: name,
      totalBytes: totalBytes,
      fileId: fileId,
      destPath: p.join(destDir, name),
    );
    _tasks.add(task);
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
    if (task.type == TransferType.upload) {
      _startUpload(task);
    } else {
      _startDownload(task);
    }
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.status == TransferStatus.completed);
    notifyListeners();
  }

  void clearAll() {
    _tasks.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  Future<void> _startUpload(TransferTask task) async {
    final token = CancelToken();
    _tokens[task.id] = token;
    task.status = TransferStatus.running;
    notifyListeners();

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
        notifyListeners();
      }

      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
        notifyListeners();
        return;
      }

      // 4. Complete upload.
      await _fileService.uploadComplete(task.uploadId!);
      task.status = TransferStatus.completed;
      task.transferredBytes = task.totalBytes;
      notifyListeners();
    } catch (e) {
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = e.toString();
        logError('Upload failed: ${task.name}', e);
      }
      notifyListeners();
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
    notifyListeners();

    try {
      await _fileService.downloadToFile(
        task.fileId!,
        task.destPath!,
        onProgress: (received, total) {
          task.transferredBytes = received;
          notifyListeners();
        },
        cancelToken: token,
      );
      if (task.cancelRequested) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.completed;
        task.transferredBytes = task.totalBytes;
      }
      notifyListeners();
    } catch (e) {
      if (task.cancelRequested || (e is DioException && e.type == DioExceptionType.cancel)) {
        task.status = TransferStatus.cancelled;
      } else {
        task.status = TransferStatus.failed;
        task.error = e.toString();
        logError('Download failed: ${task.name}', e);
      }
      notifyListeners();
    } finally {
      _tokens.remove(task.id);
    }
  }
}