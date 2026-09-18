import 'package:archive/archive.dart';

/// Minimal .docx → text extractor (a .docx is a ZIP with word/document.xml).
/// Pure Dart, no native code — feeds previews and full-text search.
abstract class DocxText {
  static bool isDocx(String name, String? mime) {
    if ((mime ?? '').toLowerCase() ==
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document') {
      return true;
    }
    return name.toLowerCase().endsWith('.docx');
  }

  /// Returns plain text or null when [bytes] are not a readable .docx.
  static String? extract(List<int> bytes) {
    try {
      if (bytes.length < 4 ||
          bytes[0] != 0x50 ||
          bytes[1] != 0x4B) {
        return null;
      }
      final archive = ZipDecoder().decodeBytes(bytes);
      ArchiveFile? doc;
      for (final f in archive.files) {
        if (f.name == 'word/document.xml') {
          doc = f;
          break;
        }
      }
      if (doc == null) return null;
      final xml = String.fromCharCodes(doc.content as List<int>);
      final buf = StringBuffer();
      // Paragraphs become newlines; text runs become text.
      final paraSplit = xml.split(RegExp(r'<w:p[ |>]'));
      for (var i = 1; i < paraSplit.length; i++) {
        final runs = RegExp(r'<w:t(?:\s[^>]*)?>(.*?)</w:t>',
                dotAll: true)
            .allMatches(paraSplit[i]);
        final line =
            runs.map((m) => _unescape(m.group(1) ?? '')).join();
        if (line.trim().isNotEmpty) buf.writeln(line);
      }
      final text = buf.toString().trim();
      return text.isEmpty ? null : text;
    } catch (_) {
      return null;
    }
  }

  static String _unescape(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");
}
