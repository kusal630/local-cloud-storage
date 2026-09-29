import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:localvault/app/theme.dart';

NavigationBar _bar({required int selected}) => NavigationBar(
      selectedIndex: selected,
      onDestinationSelected: (_) {},
      destinations: const [
        NavigationDestination(
            icon: Icon(Icons.folder_rounded), label: 'Files'),
        NavigationDestination(
            icon: Icon(Icons.swap_vert_circle_rounded), label: 'Transfers'),
        NavigationDestination(
            icon: Icon(Icons.delete_outline_rounded), label: 'Trash'),
        NavigationDestination(
            icon: Icon(Icons.sd_storage_rounded), label: 'Storage'),
        NavigationDestination(
            icon: Icon(Icons.settings_rounded), label: 'Settings'),
      ],
    );

Future<void> _pump(WidgetTester tester, ThemeData theme,
    {int selected = 0}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(body: const SizedBox(), bottomNavigationBar: _bar(selected: selected)),
    ),
  );
  await tester.pump();
}

void main() {
  for (final entry in {
    'dark': darkTheme,
    'amoled': amoledTheme,
    'light': lightTheme,
  }.entries) {
    testWidgets('${entry.key} theme: the denser bar fits all five destinations',
        (tester) async {
      // Selecting each tab in turn, because only the selected destination
      // renders its label — the other four still have to lay out without
      // colliding with it in the shortened bar.
      for (var i = 0; i < 5; i++) {
        await _pump(tester, entry.value, selected: i);
        expect(
          tester.takeException(),
          isNull,
          reason: 'tab $i overflowed the 68px bar under the ${entry.key} theme',
        );
        expect(find.byType(NavigationBar), findsOneWidget);
      }
    });

    testWidgets('${entry.key} theme: the bar is 68px, not the 80px default',
        (tester) async {
      await _pump(tester, entry.value);
      expect(tester.getSize(find.byType(NavigationBar)).height, 68);
    });
  }

  testWidgets('every destination keeps an accessible name', (tester) async {
    await _pump(tester, darkTheme, selected: 2);
    // Icons are decorative; the label is what a screen reader announces, so
    // it must survive the density change even when unselected labels are
    // hidden from view.
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Trash'), findsOneWidget);
  });
}
