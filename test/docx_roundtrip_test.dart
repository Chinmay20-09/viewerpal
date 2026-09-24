import 'dart:io';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/document_engines/document_engine.dart';
import 'package:viewerpal/document_engines/docx/docx_engine.dart';

/// Builds a small DOCX in memory containing a heading, several paragraphs
/// (with basic formatting), and a table.
Future<Uint8List> buildFixtureDocx() async {
  final doc = docx()
      .h1('Quarterly Report')
      .p('This document is used for round-trip validation.')
      .p('Bold intro with regular continuation.')
      .p('Second paragraph with more content.')
      .pageBreak()
      .table([
        ['Item', 'Qty'],
        ['Widgets', '12'],
        ['Gadgets', '7'],
      ])
      .build();
  return await DocxExporter().exportToBytes(doc);
}

/// Concatenated text of a parsed document's top-level paragraphs.
String joinedParagraphText(DocxBuiltDocument doc) => doc.elements
    .whereType<DocxParagraph>()
    .map((p) => p.children
        .whereType<DocxText>()
        .map((t) => t.content)
        .join())
    .join('\n');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File fixtureFile;
  late Uint8List fixtureBytes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('docx_roundtrip');
    fixtureBytes = await buildFixtureDocx();
    fixtureFile = File('${tempDir.path}/sample.docx')
      ..writeAsBytesSync(fixtureBytes);
  });

  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  DocumentFile makeDoc(String path, {String name = 'sample.docx'}) =>
      DocumentFile(
          uri: path, filename: name, extension: 'docx', type: DocumentType.docx);

  group('DOCX parsing', () {
    test('engine parses a valid DOCX file', () async {
      final engine = DocxDocumentEngine();
      final doc = makeDoc(fixtureFile.path);
      await engine.open(doc);
      expect(engine.isLoaded, isTrue);
      expect(engine.paragraphs(), isNotEmpty);
      engine.dispose();
    });

    test('parsed document exposes heading, paragraphs and table', () async {
      final parsed = await DocxReader.loadFromBytes(fixtureBytes);
      final paragraphs = parsed.elements.whereType<DocxParagraph>().toList();
      final tables = parsed.elements.whereType<DocxTable>().toList();

      expect(
        paragraphs.any((p) =>
            p.styleId != null &&
            p.styleId!.toLowerCase().contains('heading') &&
            p.children
                .whereType<DocxText>()
                .any((t) => t.content.contains('Quarterly Report'))),
        isTrue,
        reason: 'heading paragraph should be parsed with heading style',
      );
      expect(paragraphs.length, greaterThanOrEqualTo(4));
      expect(tables, hasLength(1));
      expect(tables.first.rows.length, 3);
    });

    test('engine rejects a file that is not a DOCX/ZIP', () async {
      final engine = DocxDocumentEngine();
      final notDocx = File('${tempDir.path}/not_a_docx.docx')
        ..writeAsStringSync('this is not a zip file');
      expect(
        () => engine.open(makeDoc(notDocx.path, name: 'not_a_docx.docx')),
        throwsA(isA<DocumentOpenException>()),
      );
      engine.dispose();
    });

    test('engine rejects an empty file', () async {
      final engine = DocxDocumentEngine();
      final empty = File('${tempDir.path}/empty.docx')..writeAsBytesSync([]);
      expect(
        () => engine.open(makeDoc(empty.path, name: 'empty.docx')),
        throwsA(isA<DocumentOpenException>()),
      );
      engine.dispose();
    });
  });

  group('DOCX text modification', () {
    test('editParagraphText replaces paragraph text and marks engine dirty',
        () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      final target =
          engine.paragraphs().firstWhere((p) => p.text.contains('Second paragraph'));
      expect(
        engine.editParagraphText(target.index, 'EDITED PARAGRAPH TEXT'),
        isTrue,
      );
      expect(engine.isDirty, isTrue);
      expect(
        engine.paragraphs().firstWhere((p) => p.text.contains('EDITED')).text,
        contains('EDITED PARAGRAPH TEXT'),
      );
      engine.dispose();
    });

    test('editParagraphText keeps paragraph but replaces its text', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      final target =
          engine.paragraphs().firstWhere((p) => p.text.contains('round-trip'));
      expect(
          engine.editParagraphText(target.index, 'Replaced paragraph body'),
          isTrue);

      final after = engine.paragraphs();
      expect(after.firstWhere((p) => p.text.contains('Replaced')).text,
          'Replaced paragraph body');
      // Heading untouched.
      expect(
          after.any(
              (p) => p.isHeading && p.text.contains('Quarterly Report')),
          isTrue);
      engine.dispose();
    });

    test('editing rejects out-of-range indices', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editParagraphText(9999, 'x'), isFalse);
      expect(engine.editParagraphText(-1, 'x'), isFalse);
      engine.dispose();
    });

    test('editing an empty paragraph inserts a text run', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      // The fixture contains a page-break paragraph with no text runs.
      final empties =
          engine.paragraphs().where((p) => p.text.isEmpty).toList();
      expect(empties, isNotEmpty);

      expect(
          engine.editParagraphText(empties.first.index, 'INSERTED'), isTrue);
      expect(
        engine
            .paragraphs()
            .firstWhere((p) => p.index == empties.first.index)
            .text,
        'INSERTED',
      );
      engine.dispose();
    });
  });

  group('DOCX export + round-trip', () {
    test('export produces non-empty bytes', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final bytes = await engine.exportBytes();
      expect(bytes, isNotEmpty);
      engine.dispose();
    });

    test('exported file is a valid ZIP (PK magic)', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final bytes = await engine.exportBytes();
      expect(bytes[0], 0x50); // 'P'
      expect(bytes[1], 0x4B); // 'K'
      engine.dispose();
    });

    test('round-trip: parse → edit → export → re-parse → verify edit',
        () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      // Modify text.
      final target = engine
          .paragraphs()
          .firstWhere((p) => p.text.contains('Second paragraph'));
      expect(
          engine.editParagraphText(
              target.index, 'The edited sentence survives export.'),
          isTrue);

      final exported = await engine.exportBytes();
      final out = File('${tempDir.path}/edited.docx')
        ..writeAsBytesSync(exported);
      engine.dispose();

      // Re-parse the exported bytes with a fresh engine (validates the app
      // can reopen what it saved).
      final engine2 = DocxDocumentEngine();
      await engine2.open(makeDoc(out.path, name: 'edited.docx'));

      final texts = engine2.paragraphs().map((p) => p.text).toList();
      expect(
        texts.any((t) => t.contains('The edited sentence survives export.')),
        isTrue,
        reason: 'modified text must persist through export',
      );
      expect(
        texts.any((t) => t.contains('Quarterly Report')),
        isTrue,
        reason: 'original heading must survive the round-trip',
      );
      expect(
        texts.any((t) => t.contains('round-trip validation')),
        isTrue,
        reason: 'untouched paragraphs must survive the round-trip',
      );

      // Table content remains readable.
      final reparsed = await DocxReader.loadFromBytes(exported);
      final tables = reparsed.elements.whereType<DocxTable>().toList();
      expect(tables, hasLength(1));
      expect(tables.first.rows.length, 3);
      final cellText = tables.first.rows[1].cells
          .map((c) => c.children
              .whereType<DocxParagraph>()
              .expand((p) => p.children.whereType<DocxText>())
              .map((t) => t.content)
              .join())
          .join('|');
      expect(cellText, contains('Widgets'));
      expect(cellText, contains('12'));

      engine2.dispose();
    });

    test('previewBytes reflects edits and caches between edits', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      final before = await engine.previewBytes();
      final target = engine
          .paragraphs()
          .firstWhere((p) => p.text.contains('Second paragraph'));
      expect(
          engine.editParagraphText(target.index, 'Preview shows this edit.'),
          isTrue);
      final after = await engine.previewBytes();

      expect(after.length, isNot(before.length));
      final reparsed = await DocxReader.loadFromBytes(after);
      expect(
        reparsed.elements
            .whereType<DocxParagraph>()
            .expand((p) => p.children.whereType<DocxText>())
            .any((t) => t.content.contains('Preview shows this edit.')),
        isTrue,
        reason: 'preview must render the edited state, not the original',
      );

      // No further edits: preview must come from cache (same instance).
      final cached = await engine.previewBytes();
      expect(identical(cached, after), isTrue);
      engine.dispose();
    });

    test('re-parsed exported document is non-empty and readable', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final exported = await engine.exportBytes();
      engine.dispose();

      final reparsed = await DocxReader.loadFromBytes(exported);
      expect(reparsed.elements, isNotEmpty);
      expect(joinedParagraphText(reparsed), contains('Quarterly Report'));
    });
  });
}
