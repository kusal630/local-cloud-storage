import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/services/transfer_manager.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Scripted upload backend. What is under test here is the queue's own
/// state machine and its listener/persistence plumbing, not the network.
class _FakeFileService extends FileService {
  _FakeFileService() : super(LocalVaultApi(session: SessionStore()));

  int chunkCalls = 0;
  int completeCalls = 0;

  @override
  Future<UploadStartResponse> uploadStart({
    required String parentId,
    required String name,
    required int size,
    required String checksum,
    String? mime,
    String? replaceFileId,
  }) async =>
      UploadStartResponse(
        uploadId: 'up-1',
        chunkSize: 5 * 1024 * 1024,
        received: 0,
      );

  @override
  Future<int> uploadChunk(String uploadId, int offset, List<int> chunk) async {
    chunkCalls++;
    return offset + chunk.length;
  }

  @override
  Future<VaultFile> uploadComplete(String uploadId) async {
    completeCalls++;
    return VaultFile(
      id: 'file-1',
      parentId: 'root',
      name: 'a.txt',
      type: 'file',
      mime: 'text/plain',
      size: 11,
      createdAt: DateTime(2026, 1, 1),
      modifiedAt: DateTime(2026, 1, 1),
    );
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  // Regression: `_changed()` used to be `void _changed() { _changed(); ... }`,
  // so every mutating call threw StackOverflowError before it could notify or
  // persist. Nothing in the suite had ever called one, so it shipped.
  test('mutating the queue notifies listeners instead of recursing', () {
    final manager = TransferManager(_FakeFileService());
    var notified = 0;
    manager.addListener(() => notified++);

    expect(manager.clearCompleted, returnsNormally);
    expect(notified, 1, reason: 'clearCompleted must notify its listeners');

    expect(manager.clearAll, returnsNormally);
    expect(notified, 2, reason: 'clearAll must notify its listeners');
  });

  test('a queued upload runs to completion and repaints as it goes', () async {
    final svc = _FakeFileService();
    final manager = TransferManager(svc);
    final dir = await Directory.systemTemp.createTemp('localvault_transfer');
    final file = File('${dir.path}/a.txt');
    await file.writeAsString('hello world');

    // Every notify is a repaint of the transfers list and the shell strip.
    final repaints = <int>[];
    manager.addListener(
      () => repaints.add(manager.tasks.isEmpty ? -1 : manager.tasks.first.transferredBytes),
    );

    manager.enqueueUpload(sourcePath: file.path, parentId: 'root', name: 'a.txt');
    expect(manager.tasks, hasLength(1),
        reason: 'the task must be queued before any I/O happens');

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (manager.tasks.single.status == TransferStatus.queued ||
        manager.tasks.single.status == TransferStatus.running) {
      if (DateTime.now().isAfter(deadline)) {
        fail('upload never reached a terminal state: '
            'status=${manager.tasks.single.status} '
            'error=${manager.tasks.single.error}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(manager.tasks.single.status, TransferStatus.completed,
        reason: 'a scripted backend must let the upload finish');
    expect(manager.tasks.single.transferredBytes,
        manager.tasks.single.totalBytes);
    expect(svc.chunkCalls, greaterThan(0), reason: 'chunks must be sent');
    expect(svc.completeCalls, 1);
    expect(repaints, isNotEmpty,
        reason: 'listeners must hear about progress, or the UI never moves');

    await dir.delete(recursive: true);
  });
}
