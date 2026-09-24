import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/document_engines/document_engine.dart';
import 'package:viewerpal/document_engines/pptx/pptx_engine.dart';

/// Builds a minimal but realistic PPTX in memory: the slide XMLs use the
/// same nesting as real PowerPoint files (`<a:t>` inside `<a:r>` runs inside
/// `<a:p>` paragraphs), plus a few non-slide package parts.
Uint8List buildFixturePptx() {
  const slideXml = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:cSld>
    <p:spTree>
      <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
      <p:grpSpPr/>
      <p:sp>
        <p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>
        <p:spPr/>
        <p:txBody>
          <a:bodyPr/><a:lstStyle/>
          <a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>SLIDE{N}TITLE</a:t></a:r></a:p>
          <a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>Bullet {N}A</a:t></a:r></a:p>
          <a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>Bullet {N}B</a:t></a:r></a:p>
          <a:p><a:endParaRPr lang="en-US"/></a:p>
        </p:txBody>
      </p:sp>
    </p:spTree>
  </p:cSld>
  <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
</p:sld>
''';
  String slide(int n) => slideXml.replaceAll('{N}', '$n');

  const contentTypes = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
  <Override PartName="/ppt/slides/slide2.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>
</Types>
''';
  const rootRels = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>
</Relationships>
''';
  const presentation = '''
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
  <p:sldIdLst>
    <p:sldId id="256" r:id="rId1"/>
    <p:sldId id="257" r:id="rId2"/>
  </p:sldIdLst>
</p:presentation>
''';

  final archive = Archive()
    ..add(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..add(ArchiveFile.string('_rels/.rels', rootRels))
    ..add(ArchiveFile.string('ppt/presentation.xml', presentation))
    ..add(ArchiveFile.string('ppt/slides/slide1.xml', slide(1)))
    ..add(ArchiveFile.string('ppt/slides/slide2.xml', slide(2)));
  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded);
}

/// Text of one archive entry (decoded), for content comparisons.
String entryText(Uint8List pptxBytes, String name) {
  final archive = ZipDecoder().decodeBytes(pptxBytes);
  final f = archive.files.firstWhere((f) => f.name == name);
  return utf8.decode(f.readBytes()!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File fixtureFile;
  late Uint8List fixtureBytes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('pptx_edit');
    fixtureBytes = buildFixturePptx();
    fixtureFile = File('${tempDir.path}/deck.pptx')
      ..writeAsBytesSync(fixtureBytes);
  });

  tearDownAll(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  DocumentFile makeDoc(String path, {String name = 'deck.pptx'}) =>
      DocumentFile(
          uri: path, filename: name, extension: 'pptx', type: DocumentType.pptx);

  group('PPTX parsing (viewing path)', () {
    test('engine opens a valid PPTX and exposes slides', () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.document, isNotNull);
      expect(engine.document!.slides, hasLength(2));
      engine.dispose();
    });

    test('extracts text nested inside a:r runs (real PowerPoint structure)',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final s1 = engine.document!.slides[0];
      expect(s1.index, 1);
      expect(s1.texts, ['SLIDE1TITLE', 'Bullet 1A', 'Bullet 1B']);
      expect(s1.title, 'SLIDE1TITLE');
      engine.dispose();
    });

    test('slides are ordered by slide number and empty paragraphs skipped',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final slides = engine.document!.slides;
      expect(slides[0].index, 1);
      expect(slides[1].index, 2);
      expect(slides[1].texts, ['SLIDE2TITLE', 'Bullet 2A', 'Bullet 2B']);
      engine.dispose();
    });

    test('engine rejects a file that is not a PPTX/ZIP', () async {
      final engine = PptxDocumentEngine();
      final notPptx = File('${tempDir.path}/not_a_pptx.pptx')
        ..writeAsStringSync('this is not a zip file');
      expect(
        () => engine.open(makeDoc(notPptx.path, name: 'not_a_pptx.pptx')),
        throwsA(isA<DocumentOpenException>()),
      );
      engine.dispose();
    });

    test('capabilities: edit and Save As allowed, in-place save is not',
        () async {
      final engine = PptxDocumentEngine();
      expect(engine.capabilities.canEdit, isTrue);
      expect(engine.capabilities.canSave, isFalse);
      expect(engine.capabilities.canSaveAs, isTrue);
      expect(
        () => engine.save(makeDoc(fixtureFile.path)),
        throwsUnsupportedError,
      );
      engine.dispose();
    });
  });

  group('PPTX text editing', () {
    test('editSlideText updates the parsed document and marks dirty',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      expect(engine.editSlideText(0, 1, 'Edited bullet'), isTrue);
      expect(engine.isDirty, isTrue);
      expect(engine.slideTexts(0), ['SLIDE1TITLE', 'Edited bullet', 'Bullet 1B']);
      // Title (paragraph 0) untouched.
      expect(engine.slideTexts(0).first, 'SLIDE1TITLE');
      engine.dispose();
    });

    test('edits reject out-of-range indices', () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editSlideText(-1, 0, 'x'), isFalse);
      expect(engine.editSlideText(99, 0, 'x'), isFalse);
      expect(engine.editSlideText(0, 99, 'x'), isFalse);
      expect(engine.isDirty, isFalse);
      engine.dispose();
    });
  });

  group('PPTX export + Save As semantics', () {
    test('export with no edits returns the original bytes unchanged',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      final out = await engine.exportBytes();
      expect(out, fixtureBytes);
      engine.dispose();
    });

    test('export rewrites only the edited slide; other parts are preserved',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editSlideText(0, 2, 'Survives export'), isTrue);
      final out = await engine.exportBytes();
      engine.dispose();

      // Valid ZIP (PK magic).
      expect(out[0], 0x50);
      expect(out[1], 0x4B);

      // Edited text present in the rewritten slide XML.
      final slide1 = entryText(out, 'ppt/slides/slide1.xml');
      expect(slide1, contains('Survives export'));
      expect(slide1, contains('SLIDE1TITLE'), reason: 'title kept');

      // Untouched slide XML has the same textual content as before.
      final slide2 = entryText(out, 'ppt/slides/slide2.xml');
      expect(slide2, contains('SLIDE2TITLE'));
      expect(slide2, contains('Bullet 2A'));

      // Non-slide package parts are byte-identical to the original.
      expect(entryText(out, '[Content_Types].xml'),
          entryText(fixtureBytes, '[Content_Types].xml'));
      expect(entryText(out, '_rels/.rels'), entryText(fixtureBytes, '_rels/.rels'));
      expect(entryText(out, 'ppt/presentation.xml'),
          entryText(fixtureBytes, 'ppt/presentation.xml'));
    });

    test('round-trip: parse → edit → export → re-open → verify', () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editSlideText(1, 0, 'New deck title'), isTrue);
      final out = await engine.exportBytes();
      final editedFile = File('${tempDir.path}/deck (edited).pptx')
        ..writeAsBytesSync(out);
      engine.dispose();

      // The app must be able to reopen what it saved (existing pipeline).
      final engine2 = PptxDocumentEngine();
      await engine2.open(makeDoc(editedFile.path, name: 'deck (edited).pptx'));
      expect(engine2.slideTexts(1).first, 'New deck title');
      // Untouched content survives the round trip.
      expect(engine2.slideTexts(0), ['SLIDE1TITLE', 'Bullet 1A', 'Bullet 1B']);
      engine2.dispose();
    });

    test('export never writes to the original file (Save As only)', () async {
      final bytesBefore = fixtureFile.readAsBytesSync();
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editSlideText(0, 0, 'Title changed'), isTrue);
      await engine.exportBytes();
      engine.dispose();
      final bytesAfter = fixtureFile.readAsBytesSync();
      expect(bytesAfter, bytesBefore,
          reason: 'the original file must never be overwritten');
    });
  });

  group('PPTX viewer widget (existing behavior intact)', () {
    testWidgets('renders slide text and navigates between slides',
        (tester) async {
      final engine = PptxDocumentEngine();
      final doc = makeDoc(fixtureFile.path);
      await tester.runAsync(() => engine.open(doc));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) =>
                Scaffold(body: engine.buildViewer(ctx, doc)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('SLIDE1TITLE'), findsOneWidget);
      expect(find.text('Slide 1 / 2'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('SLIDE2TITLE'), findsOneWidget);
      expect(find.text('Slide 2 / 2'), findsOneWidget);

      engine.dispose();
    });

    testWidgets('edit mode applies text edits via editSlideText',
        (tester) async {
      final engine = PptxDocumentEngine();
      final doc = makeDoc(fixtureFile.path);
      await tester.runAsync(() => engine.open(doc));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) =>
                Scaffold(body: engine.buildViewer(ctx, doc)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Enter edit mode.
      await tester.tap(find.text('Edit text'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Edit the title field of slide 1.
      final field = find.widgetWithText(TextField, 'SLIDE1TITLE');
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Widget roadmap Q4');
      await tester.pump();
      await tester.tap(find.text('Apply'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(engine.isDirty, isTrue);
      expect(engine.slideTexts(0).first, 'Widget roadmap Q4');

      // Back to view mode shows the edited text.
      await tester.tap(find.text('View slides'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Widget roadmap Q4'), findsOneWidget);

      engine.dispose();
    });
  });

  group('XML sanity of the rewritten slide', () {
    test('edited slide XML stays parseable with runs and properties intact',
        () async {
      final engine = PptxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      expect(engine.editSlideText(0, 0, 'Parsed again'), isTrue);
      final out = await engine.exportBytes();
      engine.dispose();

      final xml = XmlDocument.parse(entryText(out, 'ppt/slides/slide1.xml'));
      final paragraphs = xml.findAllElements('a:p').toList();
      expect(paragraphs, isNotEmpty);
      final runProps = xml.findAllElements('a:rPr').toList();
      expect(runProps, isNotEmpty,
          reason: 'run formatting properties must be preserved');
    });
  });
}
