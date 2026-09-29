import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guard for the copy deck's icon-only rule: every icon-only
/// control has to carry a `tooltip`, because it is otherwise announced as
/// nothing at all by a screen reader.
///
/// This is checked against the source rather than a pumped widget tree
/// because covering every screen would mean building every dialog, sheet and
/// overlay — most of which only exist behind a gesture. Walking `lib/` catches
/// all of them for the cost of one test.
void main() {
  test('every IconButton in lib/ declares a tooltip', () {
    final offenders = <String>[];
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: 'tests must run from the package root');

    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();

      for (final hit in _iconButtons(source)) {
        if (hit.body.contains('tooltip')) continue;
        final line = source.substring(0, hit.start).split('\n').length;
        offenders.add('${entity.path}:$line');
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'IconButtons with no tooltip are invisible to a screen reader. '
          'Add one describing the action. Offenders:\n${offenders.join('\n')}',
    );
  });
}

/// Every `IconButton(...)` invocation with its balanced-parenthesis body, so
/// nested icon/widget expressions do not end the match early. Mentions inside
/// comments are skipped — a doc comment describing the rule must not trip it.
Iterable<({int start, String body})> _iconButtons(String source) sync* {
  const needle = 'IconButton(';
  var from = 0;
  while (true) {
    final start = source.indexOf(needle, from);
    if (start < 0) return;

    final lineStart = source.lastIndexOf('\n', start) + 1;
    final prefix = source.substring(lineStart, start);
    final isComment = prefix.trimLeft().startsWith('//') ||
        prefix.trimLeft().startsWith('///');
    if (isComment) {
      from = start + needle.length;
      continue;
    }

    var i = start + needle.length;
    var depth = 1;
    while (i < source.length && depth > 0) {
      final c = source.codeUnitAt(i);
      if (c == 0x28) depth++;
      if (c == 0x29) depth--;
      i++;
    }
    yield (start: start, body: source.substring(start, i));
    from = i;
  }
}
