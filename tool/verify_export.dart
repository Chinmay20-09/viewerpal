// Verifies an on-device exported DOCX: ZIP validity, readability by the app
// parser, presence of the on-device edit, and survival of original content.
// Run with: dart run tool/verify_export.dart build/exported_device.docx
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:docx_creator/docx_creator.dart';

void main(List<String> args) async {
  final path = args.isNotEmpty ? args.first : 'build/exported_device.docx';
  final bytes = File(path).readAsBytesSync();
  final name = path.split(Platform.pathSeparator).last;

  // 1. ZIP validity.
  final archive = ZipDecoder().decodeBytes(bytes);
  final names = archive.files.map((f) => f.name).toList();
  stdout.writeln('1. Valid ZIP: yes (${archive.files.length} entries)');
  stdout.writeln(
      '   document.xml present: ${names.contains('word/document.xml')}');

  // 2. Parse with the same parser the app uses.
  final doc = await DocxReader.loadFromBytes(Uint8List.fromList(bytes));
  final paragraphs = doc.elements.whereType<DocxParagraph>().toList();
  final tables = doc.elements.whereType<DocxTable>().length;
  final texts = paragraphs
      .map((p) => p.children
          .whereType<DocxText>()
          .map((t) => t.content)
          .join())
      .toList();
  final all = texts.join('\n');

  // 3. Edited text persisted.
  final hasEdit = texts.any((t) => t.contains('EDITEDQ2 answer on device'));
  stdout.writeln(
      '2. Parsed: ${paragraphs.length} paragraphs, $tables table(s)');
  stdout.writeln(
      '3. On-device edit persisted: ${hasEdit ? "YES" : "NO"}');
  if (!hasEdit) {
    for (final t in texts) {
      if (t.contains('EDITED')) stdout.writeln('   partial match: $t');
    }
  }

  // 4. Original content survived.
  final hasOriginal =
      all.contains('Q2. Explain the background') ||
          all.contains('Digital Business');
  stdout.writeln('4. Original content survived: ${hasOriginal ? "YES" : "NO"}');
  stdout.writeln('5. $name is readable by the app parser: yes');
}
