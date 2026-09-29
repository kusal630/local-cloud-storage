import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level guard for one privacy rule: the copy a person reads must not
/// describe a protection the storage path does not provide.
///
/// `PoolStorage` — the component that splits files, encrypts the chunks with
/// AES-256-GCM and replicates them onto contributing devices — is never
/// constructed by the app, and nothing in `file_service.dart` mentions the
/// pool. Files a user uploads therefore reach their host as they are. The
/// contribute sheet nonetheless carried a section titled PRIVACY promising
/// chunks were "encrypted before they leave this device".
///
/// People decide whether to hand over a device on the strength of a claim
/// like that, so for a privacy product it is the one copy error that cannot
/// be left in. `lib/server/` and `lib/core/utils/pool_cipher.dart` are out of
/// scope on purpose: the engine exists and its own documentation may say so —
/// only the UI may not promise it.
///
/// Delete this test rather than shrinking the word list once uploads really
/// do route through `PoolStorage`. The claim will then be true by
/// construction, and a deliberate test beats a weakened one.
void main() {
  test('user-facing copy never claims encryption the upload path does not do',
      () {
    final offenders = <String>[];
    const banned = [
      'aes-256',
      'aes/gcm',
      'encrypted chunk',
      'end-to-end',
      'zero-knowledge',
      'client-side encryption',
    ];

    for (final root in ['lib/features', 'lib/widgets']) {
      final dir = Directory(root);
      expect(dir.existsSync(), isTrue,
          reason: 'tests must run from the package root');

      for (final entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsStringSync().split('\n');

        for (var i = 0; i < lines.length; i++) {
          final code = lines[i].trimLeft();
          // A doc comment describing the rule must not trip it.
          if (code.startsWith('//')) continue;

          final lower = lines[i].toLowerCase();
          for (final term in banned) {
            if (lower.contains(term)) {
              offenders.add('${entity.path}:${i + 1}: ${code.trim()}');
              break;
            }
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'The upload path performs no encryption, so no screen may say '
          'that it does. State where the files actually live instead, or '
          'wire `PoolStorage` in first. Offenders:\n${offenders.join('\n')}',
    );
  });
}
