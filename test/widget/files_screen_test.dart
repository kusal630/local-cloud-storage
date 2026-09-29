import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/providers.dart';
import 'package:localvault/client/api_client.dart';
import 'package:localvault/client/services/file_service.dart';
import 'package:localvault/client/session_store.dart';
import 'package:localvault/data/models/vault_file.dart';
import 'package:localvault/features/files/files_screen.dart';
import 'package:localvault/widgets/common.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Serves a scripted file list and a controllable sync revision, so the test
/// can drive the 10s poll deterministically.
class _FakeFileService extends FileService {
  _FakeFileService() : super(LocalVaultApi(session: SessionStore()));

  int listCalls = 0;
  int version = 1;
  List<VaultFile> items = [];

  /// When set, the next (and later) `listFiles` calls hang on this completer.
  Completer<List<VaultFile>>? pendingList;

  @override
  Future<List<VaultFile>> listFiles(String parentId,
      {bool includeTrashed = false}) {
    listCalls++;
    final pending = pendingList;
    if (pending != null) return pending.future;
    return Future.value(items);
  }

  @override
  Future<int> syncVersion() async => version;

  @override
  Future<List<VaultFile>> search(String query) async => const [];

  @override
  Future<List<ContentHit>> searchContent(String query) async => const [];
}

List<VaultFile> _files({String prefix = 'File'}) => [
      for (var i = 0; i < 30; i++)
        VaultFile(
          id: 'id-$prefix-$i',
          parentId: 'root',
          name: '$prefix ${i.toString().padLeft(2, '0')}.txt',
          type: 'file',
          mime: 'text/plain',
          size: 1024,
          createdAt: DateTime(2026, 1, 1),
          modifiedAt: DateTime(2026, 1, 2),
        ),
    ];

Future<void> _pumpFiles(WidgetTester tester, _FakeFileService svc) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [fileServiceProvider.overrideWith((ref) => svc)],
      child: const MaterialApp(home: FilesScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  testWidgets(
      'a background sync refresh keeps the rendered list instead of the skeleton',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = _FakeFileService()..items = _files();
    await _pumpFiles(tester, svc);

    // First load: the list is on screen, no skeleton.
    expect(find.byType(SkeletonList), findsNothing);
    expect(find.text('File 00.txt'), findsOneWidget);

    // Scroll into the list so we can prove the position survives.
    await tester.drag(find.byType(ListView).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)));
    expect(scrollable.position.pixels, greaterThan(0));

    // The host revision moves and the refresh stalls on a slow response.
    svc.version = 2;
    svc.pendingList = Completer<List<VaultFile>>();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    await tester.pump();

    // The current list stays on screen while the refresh is in flight.
    expect(find.byType(SkeletonList), findsNothing,
        reason: 'a background refresh must not replace the list with a skeleton');
    expect(find.byType(LinearProgressIndicator), findsOneWidget,
        reason: 'the refresh should be signalled subtly, not by blanking');
    expect(scrollable.position.pixels, greaterThan(0),
        reason: 'scroll position must survive the refresh');

    // New data lands and is swapped in.
    svc.items = _files(prefix: 'Renamed');
    svc.pendingList!.complete(_files(prefix: 'Renamed'));
    svc.pendingList = null;
    await tester.pumpAndSettle();

    expect(find.byType(SkeletonList), findsNothing);
    // The list is parked at 680px, so item 0 is far above the viewport and
    // will never be built — what matters is that every file name still on
    // screen comes from the refreshed response, not the stale one.
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((name) => name.endsWith('.txt'))
        .toList();
    expect(rendered, isNotEmpty,
        reason: 'the list must still be rendering files after the refresh');
    expect(rendered.every((name) => name.startsWith('Renamed')), isTrue,
        reason: 'the refreshed data must replace the stale list on screen');
    expect(scrollable.position.pixels, greaterThan(0));
  });

  testWidgets('the first load still shows the skeleton until data arrives',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final svc = _FakeFileService()..items = _files();
    svc.pendingList = Completer<List<VaultFile>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [fileServiceProvider.overrideWith((ref) => svc)],
        child: const MaterialApp(home: FilesScreen()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Nothing is on screen yet, so the skeleton is correct.
    expect(find.byType(SkeletonList), findsOneWidget);

    svc.items = _files();
    svc.pendingList!.complete(_files());
    svc.pendingList = null;
    await tester.pumpAndSettle();

    expect(find.byType(SkeletonList), findsNothing);
    expect(find.text('File 00.txt'), findsOneWidget);
  });
}
