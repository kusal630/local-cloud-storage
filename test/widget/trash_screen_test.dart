import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/features/trash/trash_screen.dart';

/// Scripted trash: `restoreFile` takes the row out of the trash (as the host
/// does), `deleteFile` puts it back, so an undo can be observed end to end.
class _FakeFileService extends FileService {
  _FakeFileService() : super(LocalVaultApi(session: SessionStore()));

  List<VaultFile> items = [];
  final List<String> restored = [];
  final List<String> trashed = [];

  @override
  Future<List<VaultFile>> listTrash() async => items;

  @override
  Future<HostSettings> getSettings() async => HostSettings(
        trashRetentionDays: 30,
        deviceQuotaBytes: 0,
        tlsConfigured: false,
        shareDefaultExpiryHours: 168,
      );

  @override
  Future<VaultFile> restoreFile(String id) async {
    restored.add(id);
    final file = items.firstWhere((f) => f.id == id);
    items = items.where((f) => f.id != id).toList();
    return file;
  }

  @override
  Future<void> deleteFile(String id) async {
    trashed.add(id);
    items = [
      ...items,
      VaultFile(
        id: id,
        parentId: 'root',
        name: 'notes.txt',
        type: 'file',
        size: 2048,
        createdAt: DateTime(2026, 9, 1),
        modifiedAt: DateTime(2026, 9, 2),
        deletedAt: DateTime(2026, 9, 28),
      ),
    ];
  }
}

VaultFile _trashedFile() => VaultFile(
      id: 'id-1',
      parentId: 'root',
      name: 'notes.txt',
      type: 'file',
      size: 2048,
      createdAt: DateTime(2026, 9, 1),
      modifiedAt: DateTime(2026, 9, 2),
      deletedAt: DateTime(2026, 9, 27),
    );

Future<void> _pumpTrash(WidgetTester tester, _FakeFileService svc) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [fileServiceProvider.overrideWith((ref) => svc)],
      child: const MaterialApp(home: TrashScreen()),
    ),
  );
  await tester.pump(); // resolve the loader future
  await tester.pump(const Duration(milliseconds: 300));
}

/// Unmounts the tree (cancels widget timers, including the SnackBar's) and
/// flushes the haptic `Future.delayed` timers so the fake clock is clean.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('restore confirms with a snackbar whose Undo moves it back',
      (tester) async {
    final svc = _FakeFileService()..items = [_trashedFile()];
    await _pumpTrash(tester, svc);

    expect(find.text('notes.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Actions for notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    // The success path is no longer mute, and it carries the way back.
    expect(svc.restored, ['id-1']);
    expect(find.text("'notes.txt' is back in your files."), findsOneWidget);
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(svc.trashed, ['id-1']);
    expect(find.text("'notes.txt' moved back to trash."), findsOneWidget);
    // The row is in the list again — the undo actually changed state.
    expect(find.text('notes.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _teardown(tester);
  });

  testWidgets('a failed restore still says what to do next', (tester) async {
    final svc = _FailingRestoreService();
    svc.items = [_trashedFile()];
    await _pumpTrash(tester, svc);

    await tester.tap(find.byTooltip('Actions for notes.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not restore that file. Pull down to try again.'),
      findsOneWidget,
    );
    expect(find.text('Undo'), findsNothing); // nothing to undo
    await _teardown(tester);
  });
}

/// Restore throws — the failure snackbar (friendly, sentence case, next step)
/// must survive the new success path untouched.
class _FailingRestoreService extends _FakeFileService {
  @override
  Future<VaultFile> restoreFile(String id) async =>
      throw StateError('host unreachable');
}
