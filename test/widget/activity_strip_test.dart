import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/client/services/transfer_manager.dart';
import 'package:localvault/widgets/activity_strip.dart';

TransferTask _task({
  required String name,
  required TransferStatus status,
  TransferType type = TransferType.upload,
  int totalBytes = 1000,
  int transferredBytes = 0,
}) {
  final task = TransferTask(
    id: 'id-$name',
    type: type,
    name: name,
    totalBytes: totalBytes,
  );
  task.status = status;
  task.transferredBytes = transferredBytes;
  return task;
}

Future<void> _pump(WidgetTester tester, List<TransferTask> tasks,
    {VoidCallback? onOpen}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ActivityStrip(tasks: tasks, onOpen: onOpen ?? () {}),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an idle queue renders nothing at all', (tester) async {
    await _pump(tester, [
      _task(name: 'done.txt', status: TransferStatus.completed),
      _task(name: 'bad.txt', status: TransferStatus.failed),
      _task(name: 'gone.txt', status: TransferStatus.cancelled),
    ]);

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(Icon), findsNothing);
    expect(tester.getSize(find.byType(ActivityStrip)).height, 0);
  });

  testWidgets('a running upload names the file and shows its share of the work',
      (tester) async {
    await _pump(tester, [
      _task(
        name: 'photo.jpg',
        status: TransferStatus.running,
        totalBytes: 1000,
        transferredBytes: 250,
      ),
    ]);

    expect(find.text('Uploading photo.jpg'), findsOneWidget);
    expect(find.text('25%'), findsOneWidget);

    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0.25);
  });

  testWidgets('a running download reads as a download, not an upload',
      (tester) async {
    await _pump(tester, [
      _task(
        name: 'video.mp4',
        status: TransferStatus.running,
        type: TransferType.download,
        totalBytes: 100,
        transferredBytes: 50,
      ),
    ]);

    expect(find.text('Downloading video.mp4'), findsOneWidget);
    expect(find.text('Uploading video.mp4'), findsNothing);
    expect(find.text('50%'), findsOneWidget);
  });

  testWidgets('several running transfers are counted, not listed',
      (tester) async {
    await _pump(tester, [
      _task(name: 'a.txt', status: TransferStatus.running, totalBytes: 10),
      _task(name: 'b.txt', status: TransferStatus.running, totalBytes: 10),
      _task(name: 'c.txt', status: TransferStatus.running, totalBytes: 10),
    ]);

    expect(find.text('Uploading 3 files'), findsOneWidget);
    // Totals are summed across every running transfer, not just the first.
    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, 0);
  });

  testWidgets('a queued-only queue says waiting instead of implying motion',
      (tester) async {
    await _pump(tester, [
      _task(name: 'photo.jpg', status: TransferStatus.queued),
      _task(name: 'notes.txt', status: TransferStatus.queued),
    ]);

    expect(find.text('2 files waiting to upload'), findsOneWidget);
    // Nothing has moved, so there is no percentage to claim.
    expect(find.textContaining('%'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('a single queued file is singular', (tester) async {
    await _pump(tester, [_task(name: 'photo.jpg', status: TransferStatus.queued)]);

    expect(find.text('One file waiting to upload'), findsOneWidget);
  });

  testWidgets('an unknown transfer size is indeterminate, not a fake number',
      (tester) async {
    await _pump(tester, [
      _task(
        name: 'huge.iso',
        status: TransferStatus.running,
        totalBytes: 0,
      ),
    ]);

    final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator));
    expect(bar.value, isNull, reason: 'no size means no honest percentage');
    expect(find.textContaining('%'), findsNothing);
    expect(find.text('Uploading huge.iso'), findsOneWidget);
  });

  testWidgets('tapping the strip opens transfers', (tester) async {
    var opened = 0;
    await _pump(
      tester,
      [_task(name: 'photo.jpg', status: TransferStatus.running, totalBytes: 10)],
      onOpen: () => opened++,
    );

    await tester.tap(find.byType(ActivityStrip));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the strip meets the 44px touch-target floor when it shows',
      (tester) async {
    await _pump(tester, [
      _task(name: 'photo.jpg', status: TransferStatus.running, totalBytes: 10),
    ]);

    expect(tester.getSize(find.byType(ActivityStrip)).height, greaterThanOrEqualTo(44));
  });

  testWidgets('a running transfer reports throughput alongside progress',
      (tester) async {
    final task = _task(
      name: 'photo.jpg',
      status: TransferStatus.running,
      totalBytes: 1000,
      transferredBytes: 250,
    );
    task.speedBps = 4.4 * 1024 * 1024;
    await _pump(tester, [task]);

    expect(find.textContaining('/s'), findsOneWidget,
        reason: 'throughput is the fastest read on whether a transfer is alive');
    expect(find.textContaining('25%'), findsOneWidget);
  });

  testWidgets('the strip announces itself as a button', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, [
      _task(name: 'photo.jpg', status: TransferStatus.running, totalBytes: 10),
    ]);

    // Merged with the child text, so match the announcement rather than
    // demanding an exact string.
    expect(
      find.bySemanticsLabel(RegExp('Open transfers')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('Uploading photo\\.jpg')),
      findsOneWidget,
    );
    // Disposed inline: flutter_test verifies handles before it runs
    // `addTearDown` callbacks, so deferring it trips a leak assertion.
    semantics.dispose();
  });
}
