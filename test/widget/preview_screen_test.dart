import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/audit_entry.dart';
import 'package:localvault/data/models/file_comment.dart';
import 'package:localvault/data/models/file_version.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/features/preview/preview_screen.dart';

/// FileService double: serves one file, everything else is overridable.
class _FakeFileService extends FileService {
  _FakeFileService(this.file) : super(LocalVaultApi(session: SessionStore()));

  final VaultFile file;

  /// Flip back to false to exercise the retry path.
  bool commentsFail = true;

  @override
  Future<List<VaultFile>> listFiles(String parentId,
          {bool includeTrashed = false}) async =>
      [file];

  @override
  Future<void> touchOpen(String id) async {}

  @override
  Future<List<FileComment>> listComments(String fileId) async {
    if (commentsFail) throw Exception('comments unavailable');
    return <FileComment>[];
  }

  @override
  Future<List<AuditEntry>> activityFor(String targetId, {int limit = 50}) async =>
      <AuditEntry>[];

  @override
  Future<List<FileVersion>> listVersions(String fileId) async =>
      <FileVersion>[];
}

VaultFile _file() => VaultFile(
      id: 'f1',
      parentId: 'root',
      name: 'report.xyz',
      type: 'file',
      size: 2048,
      createdAt: DateTime(2026, 9, 1),
      modifiedAt: DateTime(2026, 9, 2),
    );

Future<void> _pumpPreview(WidgetTester tester, _FakeFileService fake) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [fileServiceProvider.overrideWithValue(fake)],
      child: const MaterialApp(home: PreviewScreen(fileId: 'f1')),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

/// An indeterminate spinner — the "still loading" signal. Determinate
/// indicators (the storage donut) do not count.
bool _isSpinning(Widget widget) =>
    widget is CircularProgressIndicator && widget.value == null;

void main() {
  testWidgets('comment load failure shows an error with retry, not a spinner',
      (tester) async {
    final fake = _FakeFileService(_file());
    await _pumpPreview(tester, fake);

    final error = find.text("Couldn't load comments. Tap Retry to try again.");
    await tester.scrollUntilVisible(
      error,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(error);
    await tester.pump();

    expect(error, findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byWidgetPredicate(_isSpinning), findsNothing);

    // Recoverable: once the service answers, retry replaces the error.
    fake.commentsFail = false;
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(error, findsNothing);
    expect(
      find.text('No comments yet — start the discussion.'),
      findsOneWidget,
    );
  });
}
