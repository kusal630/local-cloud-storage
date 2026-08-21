import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/widgets/common.dart';

void main() {
  testWidgets('EmptyState widget shows icon and title', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: EmptyState(
            icon: Icons.folder_open,
            title: 'No files yet',
            subtitle: 'Upload some files',
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.folder_open), findsOneWidget);
    expect(find.text('No files yet'), findsOneWidget);
    expect(find.text('Upload some files'), findsOneWidget);
  });

  testWidgets('ErrorState widget shows message and retry', (tester) async {
    var retried = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ErrorState(
            message: 'Something went wrong',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('LoadingIndicator shows message', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: LoadingIndicator(message: 'Loading...'),
        ),
      ),
    );

    expect(find.text('Loading...'), findsOneWidget);
  });

  test('formatBytes returns correct strings', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1023), '1023 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1024 * 1024), '1.0 MB');
    expect(formatBytes(1024 * 1024 * 1024), '1.0 GB');
  });
}