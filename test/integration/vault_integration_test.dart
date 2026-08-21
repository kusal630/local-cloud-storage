import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/data/datasources/vault.dart';
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

  test('Server start and health check', () async {
    final storageDir = Directory('${Directory.systemTemp.path}/lv_server_${DateTime.now().millisecondsSinceEpoch}');
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
}