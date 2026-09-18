import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/data/datasources/vault.dart';
import 'package:localvault/server/host_runner.dart';
import 'package:localvault/server/server.dart';

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

  test('Wave2: favorites, recent, versions, audit, settings, breakdown',
      () async {
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
}