import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/server/host_runner.dart';
import 'package:localvault/server/server.dart';
import 'package:localvault/server/services/token_service.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('Vault creation and basic operations', () async {
    final storageDir = Directory('${Directory.systemTemp.path}/lv_test_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      expect(vault.isSetup, isFalse);
      expect(vault.vaultDir.existsSync(), isTrue);
      expect(Directory('${storageDir.path}/.localvault/blobs').existsSync(), isTrue);

      await vault.completeSetup(password: 'testpass123', deviceName: 'Test Host');
      expect(vault.isSetup, isTrue);

      final folder = vault.files.createFolder('root', 'Documents');
      expect(folder.name, 'Documents');
      expect(folder.isFolder, isTrue);

      final subfolder = vault.files.createFolder(folder.id, 'Images');
      expect(subfolder.name, 'Images');
      expect(subfolder.parentId, folder.id);

      final items = vault.files.listChildren('root');
      expect(items.length, 1);
      expect(items.first.name, 'Documents');

      vault.files.softDelete(folder.id);
      final trashed = vault.files.listTrash();
      expect(trashed.length, 2);
      expect(trashed.first.isTrashed, isTrue);

      vault.files.restore(folder.id);
      final restored = vault.files.listChildren('root');
      expect(restored.length, 1);

      final usage = vault.files.usage();
      expect(usage.vaultBytes, greaterThanOrEqualTo(0));
      expect(usage.trashBytes, 0);

      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('Duplicate name auto-renaming', () async {
    final storageDir = Directory('${Directory.systemTemp.path}/lv_dup_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');

      final f1 = vault.files.createFolder('root', 'Docs');
      final f2 = vault.files.createFolder('root', 'Docs');
      final f3 = vault.files.createFolder('root', 'Docs');

      expect(f1.name, 'Docs');
      expect(f2.name, 'Docs (1)');
      expect(f3.name, 'Docs (2)');

      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('Circular move prevention', () async {
    final storageDir = Directory('${Directory.systemTemp.path}/lv_move_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');

      final a = vault.files.createFolder('root', 'A');
      final b = vault.files.createFolder(a.id, 'B');
      final c = vault.files.createFolder(b.id, 'C');

      expect(
        () => vault.files.move(a.id, c.id),
        throwsA(isA<Exception>()),
      );

      final moved = vault.files.move(c.id, 'root');
      expect(moved.parentId, 'root');

      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('Server start and health check', () async {    final storageDir = Directory('${Directory.systemTemp.path}/lv_server_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test Host');
      final server = LocalVaultServer(vault: vault);

      final port = await server.start();
      expect(port, greaterThan(0));
      expect(server.isRunning, isTrue);

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse('http://127.0.0.1:$port/health'));
      final response = await request.close();
      expect(response.statusCode, 200);

      await server.stop();
      expect(server.isRunning, isFalse);
      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('Research wave: tags, comments, shares, duplicates, archive', () async {
    final storageDir = Directory(
        '${Directory.systemTemp.path}/lv_research_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');

      // Tags.
      final folder = vault.files.createFolder('root', 'Work');
      final tagged = vault.files.setTags(folder.id, ['Work', 'URGENT!!', 'a']);
      expect(tagged.tags, ['work', 'a']);
      final tags = vault.files.listTags();
      expect(tags.any((t) => t.tag == 'work' && t.count == 1), isTrue);
      expect(vault.files.listByTag('work').length, 1);

      // Comments.
      final comment = vault.comments.add(
        fileId: folder.id,
        author: 'tester',
        body: 'hello',
      );
      expect(comment.body, 'hello');
      expect(vault.comments.listForFile(folder.id).length, 1);
      vault.comments.delete(comment.id);
      expect(vault.comments.listForFile(folder.id), isEmpty);

      // Download share round-trip (repo level).
      final created = await vault.shares.create(
        fileId: folder.id,
        fileName: folder.name,
      );
      expect(created.token.length, 64);
      final row = vault.shares.resolve(created.token);
      expect(row['file_id'], folder.id);

      // Upload-request share round-trip.
      final req = await vault.shares.create(
        fileName: 'Upload to Work',
        mode: 'upload',
        targetFolderId: folder.id,
      );
      final reqRow = vault.shares.resolve(req.token);
      expect(reqRow['mode'], 'upload');
      expect(reqRow['target_folder_id'], folder.id);

      // Duplicates: same bytes twice → one group.
      final src = File('${storageDir.path}/dup.txt');
      await src.writeAsString('same-bytes');
      const checksum =
          'b1b1bd16835d3cedfa8a876a3f7d3c4b9f3e0b8b0b0b0b0b0b0b0b0b0b0b0b0';
      final blob = await vault.storeBlob(
        sourcePath: src.path,
        size: await src.length(),
        checksum: checksum,
        mimeType: 'text/plain',
      );
      vault.files.createFile(
        parentId: 'root',
        name: 'a.txt',
        size: 10,
        checksum: checksum,
        blobId: blob.id,
      );
      final src2 = File('${storageDir.path}/dup2.txt');
      await src2.writeAsString('same-bytes');
      final blob2 = await vault.storeBlob(
        sourcePath: src2.path,
        size: await src2.length(),
        checksum: checksum,
        mimeType: 'text/plain',
      );
      vault.files.createFile(
        parentId: 'root',
        name: 'b.txt',
        size: 10,
        checksum: checksum,
        blobId: blob2.id,
      );
      final dups = vault.files.duplicates();
      expect(dups.length, 1);
      expect(dups.first.files.length, 2);

      // Copy: file copy shares the blob; folder copy recurses.
      final copied =
          vault.files.copyItem(dups.first.files.first.id, 'root');
      expect(copied.blobId, isNotNull);
      final sub = vault.files.createFolder(folder.id, 'sub');
      final folderCopy = vault.files.copyItem(folder.id, 'root');
      expect(folderCopy.isFolder, isTrue);
      expect(
          vault.files
              .listChildren(folderCopy.id)
              .any((f) => f.name == 'sub'),
          isTrue);
      expect(sub.id == folderCopy.id, isFalse);

      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('Research wave: folder archive over HTTP', () async {    final storageDir = Directory(
        '${Directory.systemTemp.path}/lv_zip_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);
    LocalVaultServer? server;
    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');
      final folder = vault.files.createFolder('root', 'Pack');
      final src = File('${storageDir.path}/z.txt');
      await src.writeAsString('zip-me');
      final blob = await vault.storeBlob(
        sourcePath: src.path,
        size: await src.length(),
        checksum:
            'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
        mimeType: 'text/plain',
      );
      vault.files.createFile(
        parentId: folder.id,
        name: 'z.txt',
        size: 6,
        checksum:
            'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
        blobId: blob.id,
      );

      server = LocalVaultServer(vault: vault);
      final port = await server.start();
      final tokens = TokenService(vault);
      final device = tokens.createDevice(
        deviceId: const Uuid().v4(),
        deviceName: 'zip-test',
      );

      final client = HttpClient();
      final request = await client.getUrl(Uri.parse(
          'http://127.0.0.1:$port/api/v1/files/${folder.id}/archive'));
      request.headers.set('authorization', 'Bearer ${device.accessToken}');
      final response = await request.close();
      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'application/zip');
      final bytes = await response.fold<List<int>>(
          [], (all, chunk) => all..addAll(chunk));
      // ZIP local file header magic.
      expect(bytes.length, greaterThan(4));
      expect(bytes[0], 0x50);
      expect(bytes[1], 0x4B);
      client.close();
      await server.stop();
      server = null;
      vault.close();
    } finally {
      try {
        await server?.stop();
      } catch (_) {}
      await storageDir.delete(recursive: true);
    }
  });

  test('HostRunner serves HTTPS on a background isolate', () async {
    final storageDir = Directory(
        '${Directory.systemTemp.path}/lv_runner_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    HostRunner? runner;
    try {
      final created = await Vault.create(storageDir);
      await created.completeSetup(
          password: 'testpass', deviceName: 'Runner Host');
      created.close();

      runner = await HostRunner.start(
          storagePath: storageDir.path, preferredPort: 0);
      expect(runner.isRunning, isTrue);
      expect(runner.port, greaterThan(0));
      // Auto-TLS: fingerprint looks like hex sha256.
      expect(runner.fingerprint, isNotNull);
      expect(runner.fingerprint!.length, 64);

      final client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
      final request = await client.getUrl(Uri.parse(
          'https://127.0.0.1:${runner.port}/health'));
      final response = await request.close();
      expect(response.statusCode, 200);
      client.close();

      // Pairing RPC crosses the isolate boundary.
      final devices = runner.vault.devices.listAll();
      expect(devices, isNotEmpty);
      final code =
          await runner.ensurePairingCode(devices.first.id);
      expect(code.length, 6);

      await runner.stop();
      runner = null;
      expect(runner == null, isTrue);
    } finally {
      try {
        await runner?.stop();
      } catch (_) {}
      await storageDir.delete(recursive: true);
    }
  });

  test('Wave2: favorites, recent, versions, audit, settings, breakdown',      () async {
    final storageDir = Directory(
        '${Directory.systemTemp.path}/lv_wave2_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);

    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');

      // Migrations ran: settings defaults present.
      expect(vault.settings.trashRetentionDays, 30);
      expect(vault.settings.deviceQuotaBytes, 0);

      // quirk: quota enforcement (unlimited by default).
      vault.enforceQuota(1 << 40);
      vault.settings.deviceQuotaBytes = 100;
      expect(() => vault.enforceQuota(101), throwsA(isA<Exception>()));
      vault.settings.deviceQuotaBytes = 0;

      // Favorites + recent.
      final folder = vault.files.createFolder('root', 'Docs');
      var starred = vault.files.setFavorite(folder.id, true);
      expect(starred.isFavorite, isTrue);
      expect(vault.files.listFavorites().length, 1);
      vault.files.touchOpened(folder.id);
      expect(vault.files.listRecent().length, 1);

      // Versions: real blob via a temp source file.
      final src = File('${storageDir.path}/hello.txt');
      await src.writeAsString('hello world');
      final blob = await vault.storeBlob(
        sourcePath: src.path,
        size: await src.length(),
        checksum:
            'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        mimeType: 'text/plain',
      );
      final file = vault.files.createFile(
        parentId: 'root',
        name: 'hello.txt',
        size: 11,
        checksum:
            'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9',
        blobId: blob.id,
        mime: 'text/plain',
      );
      vault.versions.snapshot(
        fileId: file.id,
        blobId: file.blobId,
        size: file.size,
        checksum: file.checksum,
        mime: file.mime,
      );
      final versions = vault.versions.listForFile(file.id);
      expect(versions.length, 1);
      expect(versions.first.version, 1);

      // Audit log.
      vault.auditAction(action: 'file.upload', targetId: file.id);
      expect(vault.audit.recent(limit: 5).length, 1);

      // Breakdown counts the live file.
      final breakdown = vault.files.breakdown();
      expect(breakdown['docs'], 11);

      // Retention purge with 0 days disabled.
      vault.settings.trashRetentionDays = 0;
      expect(await vault.purgeExpiredTrash(), 0);

      vault.close();
    } finally {
      await storageDir.delete(recursive: true);
    }
  });

  test('WebDAV round-trip: MKCOL, PUT, PROPFIND, GET, LOCK, MOVE, DELETE',
      () async {
    final storageDir = Directory(
        '${Directory.systemTemp.path}/lv_dav_${DateTime.now().millisecondsSinceEpoch}');
    await storageDir.create(recursive: true);
    LocalVaultServer? server;
    try {
      final vault = await Vault.create(storageDir);
      await vault.completeSetup(password: 'testpass', deviceName: 'Test');
      server = LocalVaultServer(vault: vault);
      final port = await server.start();

      final basic = base64Encode(utf8.encode('owner:testpass'));
      Future<HttpClientResponse> dav(String method, String path,
          {Map<String, String>? headers, String? body}) async {
        final client = HttpClient();
        final request =
            await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
        request.headers.set('authorization', 'Basic $basic');
        headers?.forEach(request.headers.set);
        if (body != null) request.write(body);
        final response = await request.close();
        await response.drain();
        return response;
      }

      Future<String> davBody(String method, String path,
          {Map<String, String>? headers, String? body}) async {
        final client = HttpClient();
        final request =
            await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
        request.headers.set('authorization', 'Basic $basic');
        headers?.forEach(request.headers.set);
        if (body != null) request.write(body);
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();
        client.close();
        return text;
      }

      // Unauthorized without credentials.
      final anon = HttpClient();
      final anonReq = await anon.openUrl(
          'PROPFIND', Uri.parse('http://127.0.0.1:$port/dav/'));
      final anonRes = await anonReq.close();
      await anonRes.drain();
      expect(anonRes.statusCode, 401);
      anon.close();

      expect((await dav('MKCOL', '/dav/Docs')).statusCode, 201);
      expect(
          (await dav('PUT', '/dav/Docs/n.txt', body: 'hello webdav'))
              .statusCode,
          201);
      final listing = await davBody('PROPFIND', '/dav/Docs',
          headers: {'depth': '1'});
      expect(listing, contains('n.txt'));
      expect(listing, contains('multistatus'));
      final content =
          await davBody('GET', '/dav/Docs/n.txt');
      expect(content, 'hello webdav');

      // Locking: write without token is rejected.
      final lockRes = await dav('LOCK', '/dav/Docs/n.txt');
      expect(lockRes.statusCode, 200);
      final lockToken = lockRes.headers.value('lock-token') ?? '';
      expect(lockToken, isNotEmpty);
      final lockedPut =
          await dav('PUT', '/dav/Docs/n.txt', body: 'blocked');
      expect(lockedPut.statusCode, 423);
      // Write with the token succeeds; then unlock.
      expect(
          (await dav('PUT', '/dav/Docs/n.txt',
                  headers: {'if': ' (<$lockToken>)'}, body: 'unblocked'))
              .statusCode,
          204);
      expect(
          (await dav('UNLOCK', '/dav/Docs/n.txt',
                  headers: {'lock-token': lockToken}))
              .statusCode,
          204);

      // Move + copy.
      expect(
          (await dav('MOVE', '/dav/Docs/n.txt', headers: {
            'destination': 'http://127.0.0.1:$port/dav/Docs/m.txt'
          }))
              .statusCode,
          anyOf([201, 204]));
      expect(await davBody('GET', '/dav/Docs/m.txt'), 'unblocked');
      expect(
          (await dav('COPY', '/dav/Docs/m.txt', headers: {
            'destination': 'http://127.0.0.1:$port/dav/Docs/c.txt'
          }))
              .statusCode,
          anyOf([201, 204]));
      expect(await davBody('GET', '/dav/Docs/c.txt'), 'unblocked');
      expect((await dav('DELETE', '/dav/Docs/c.txt')).statusCode, 204);

      await server.stop();
      server = null;
      vault.close();
    } finally {
      try {
        await server?.stop();
      } catch (_) {}
      await storageDir.delete(recursive: true);
    }
  });
}