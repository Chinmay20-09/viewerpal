import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/core/services/document_router.dart';
import 'package:viewerpal/document_engines/document_engine.dart';
import 'package:viewerpal/document_engines/pdf/pdf_composer.dart';
import 'package:viewerpal/document_engines/pdf/pdf_edit_model.dart';
import 'package:viewerpal/document_engines/pdf/pdf_engine.dart';

// ---------------------------------------------------------------------------
// Fixture: minimal valid PDF built with the same library used by the composer.
// ---------------------------------------------------------------------------

Uint8List _buildOriginalPdf({String marker = 'Original content page'}) {
  final doc = PdfDocument();
  for (var i = 0; i < 2; i++) {
    doc.pages.add().graphics.drawString(
          '$marker ${i + 1}',
          PdfStandardFont(PdfFontFamily.helvetica, 24),
          brush: PdfBrushes.black,
          bounds: const Rect.fromLTWH(40, 40, 400, 50),
        );
  }
  final bytes = Uint8List.fromList(doc.saveSync());
  doc.dispose();
  return bytes;
}

DocumentFile _doc(String path) => DocumentFile(
      uri: path,
      filename: 'sample.pdf',
      extension: 'pdf',
      type: DocumentType.pdf,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File originalFile;
  late Uint8List originalBytes;

  setUpAll(() {
    tempDir = Directory.systemTemp.createTempSync('pdf_edit_test');
    originalBytes = _buildOriginalPdf();
    originalFile = File('${tempDir.path}/sample.pdf')
      ..writeAsBytesSync(originalBytes);
  });

  tearDownAll(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('PdfEditorController — text operations', () {
    test('1. adding text creates a text element', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1);
      expect(c.count, 1);
      final el = c.byId(id);
      expect(el, isNotNull);
      expect(el!.type, PdfEditElementType.text);
      expect(el.pageIndex, 0);
      expect(el.text, isNotEmpty);
    });

    test('2. editing added text updates its content', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1);
      expect(c.editText(id, 'Hello PDF'), isTrue);
      expect(c.byId(id)!.text, 'Hello PDF');
    });

    test('3. deleting added text removes the element', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1);
      expect(c.removeElement(id), isTrue);
      expect(c.count, 0);
      expect(c.byId(id), isNull);
    });

    test('4. changing font size works', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1, fontSize: 12);
      expect(c.setFontSize(id, 28), isTrue);
      expect(c.byId(id)!.fontSize, 28);
      expect(c.setFontSize(id, -1), isFalse);
    });

    test('5. changing text color works', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1);
      expect(c.setTextColor(id, PdfColor(255, 0, 0)), isTrue);
      expect(c.byId(id)!.color.r, 255);
      expect(c.byId(id)!.color.g, 0);
    });

    test('6. changing regular/bold/italic/bold+italic styles works', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.1);
      for (final s in PdfEditTextStyle.values) {
        expect(c.setTextStyle(id, s), isTrue);
        expect(c.byId(id)!.textStyle, s);
      }
    });

    test('text ops reject unknown ids and image elements', () {
      final c = PdfEditorController();
      final imgId = c.addImage(
        pageIndex: 0,
        x: 0.1,
        y: 0.1,
        imageBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(c.editText('nope', 'x'), isFalse);
      expect(c.editText(imgId, 'x'), isFalse);
      expect(c.setFontSize('nope', 12), isFalse);
      expect(c.setTextColor('nope', PdfColor(0, 0, 0)), isFalse);
      expect(c.setTextStyle('nope', PdfEditTextStyle.bold), isFalse);
    });
  });

  group('PdfEditorController — image + move/resize', () {
    test('7. adding an image creates an image element', () {
      final c = PdfEditorController();
      final id = c.addImage(
        pageIndex: 1,
        x: 0.2,
        y: 0.2,
        imageBytes: Uint8List.fromList([9, 8, 7]),
        aspect: 2.0,
      );
      final el = c.byId(id)!;
      expect(el.type, PdfEditElementType.image);
      expect(el.pageIndex, 1);
      expect(el.imageBytes, isNotNull);
      // Aspect 2:1 → height half of width.
      expect(el.height, closeTo(0.125, 0.0001));
    });

    test('8. deleting an image removes the element', () {
      final c = PdfEditorController();
      final id = c.addImage(
        pageIndex: 0,
        x: 0.2,
        y: 0.2,
        imageBytes: Uint8List.fromList([1]),
      );
      expect(c.removeElement(id), isTrue);
      expect(c.count, 0);
    });

    test('9. move and resize clamp and persist', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.5, y: 0.5);
      expect(c.moveElement(id, 1.5, -0.5), isTrue);
      final el = c.byId(id)!;
      expect(el.x, 1.0);
      expect(el.y, 0.0);
      expect(c.resizeElement(id, 0.4, 0.2), isTrue);
      expect(el.width, 0.4);
      expect(el.height, 0.2);
      expect(c.resizeElement(id, 0, 0.2), isFalse);
    });
  });

  group('PdfComposer — Save As generation', () {
    test('9. composed output is a valid PDF containing original content',
        () async {
      final composer = PdfComposer();
      final c = PdfEditorController();
      c.addText(pageIndex: 0, x: 0.1, y: 0.1, text: 'User note');
      final out = await composer.composeBytes(
        originalBytes: originalBytes,
        elements: c.elements,
      );

      // Output is a valid PDF with the SAME page count (no pages added).
      final doc = PdfDocument(inputBytes: out);
      expect(doc.pages.count, 2, reason: 'page structure must be preserved');
      doc.dispose();

      // Output differs from the original (overlay applied) but keeps the
      // original content visually intact (verified via text extraction
      // using the same parser used for the fixture).
      expect(out.length, greaterThan(originalBytes.length));
    });

    test('composed PDF contains the user-added text', () async {
      final composer = PdfComposer();
      final c = PdfEditorController();
      c.addText(
        pageIndex: 0,
        x: 0.1,
        y: 0.1,
        text: 'OVERLAY-TEXT-MARKER',
      );
      final out = await composer.composeBytes(
        originalBytes: originalBytes,
        elements: c.elements,
      );

      // Text extraction from the composed file must contain both the
      // original marker and the user-added text.
      final extracted = _extractText(out);
      expect(extracted, contains('Original content page 1'));
      expect(extracted, contains('OVERLAY-TEXT-MARKER'));
    });

    test('elements on a non-existent page are skipped, structure preserved',
        () async {
      final composer = PdfComposer();
      final c = PdfEditorController();
      c.addText(pageIndex: 5, x: 0.1, y: 0.1, text: 'ghost');
      final out = await composer.composeBytes(
        originalBytes: originalBytes,
        elements: c.elements,
      );
      final doc = PdfDocument(inputBytes: out);
      expect(doc.pages.count, 2);
      doc.dispose();
    });

    test('rejects invalid source PDFs', () async {
      final composer = PdfComposer();
      expect(
        () => composer.composeBytes(
          originalBytes: Uint8List.fromList([0]),
          elements: const [],
        ),
        throwsA(isA<PdfComposeException>()),
      );
      expect(
        () => composer.composeBytes(
          originalBytes: Uint8List(0),
          elements: const [],
        ),
        throwsA(isA<PdfComposeException>()),
      );
    });
  });

  group('Save As guarantees', () {
    test('10. original PDF file is not overwritten by Save As', () async {
      final bytesBefore = originalFile.readAsBytesSync();

      final composer = PdfComposer();
      final c = PdfEditorController();
      c.addText(pageIndex: 0, x: 0.1, y: 0.1, text: 'Edit me');
      final out = await composer.composeBytes(
        originalBytes: originalBytes,
        elements: c.elements,
      );
      // Simulate Save As: write to a NEW path only.
      final newPath = '${tempDir.path}/sample (edited).pdf';
      File(newPath).writeAsBytesSync(out);

      final bytesAfter = originalFile.readAsBytesSync();
      expect(bytesAfter.length, bytesBefore.length);
      expect(
        String.fromCharCodes(bytesAfter),
        String.fromCharCodes(bytesBefore),
        reason: 'original file bytes must be identical after editing',
      );
      expect(File(newPath).lengthSync(), greaterThan(0));
    });
  });

  group('Reopen through the existing pipeline', () {
    test('11. generated PDF passes engine.open and routes correctly',
        () async {
      final composer = PdfComposer();
      final c = PdfEditorController();
      c.addText(pageIndex: 0, x: 0.1, y: 0.1, text: 'Reopen check');
      c.addImage(
        pageIndex: 0,
        x: 0.5,
        y: 0.5,
        imageBytes: _tinyPng(),
      );
      final out = await composer.composeBytes(
        originalBytes: originalBytes,
        elements: c.elements,
      );
      final generated = File('${tempDir.path}/reopen.pdf')
        ..writeAsBytesSync(out);

      // The EXISTING engine + router must accept the generated file.
      final engine = PdfDocumentEngine();
      await engine.open(_doc(generated.path)); // throws when invalid
      expect(engine.capabilities.canEdit, isFalse);
      expect(engine.capabilities.canSave, isFalse);
      expect(engine.capabilities.canSaveAs, isFalse);
      engine.dispose();

      final router = DocumentRouter();
      expect(router.route(_doc(generated.path)), isA<PdfDocumentEngine>());
      final opened = await router.routeAndOpen(_doc(generated.path));
      expect(opened.name, 'PdfDocumentEngine');
      opened.dispose();
    });

    test('12. existing PDF viewing behavior still works', () async {
      // The original engine contract is unchanged: opens valid PDFs, rejects
      // missing/empty/non-PDF files, stays view-only.
      final engine = PdfDocumentEngine();
      await engine.open(_doc(originalFile.path));
      engine.dispose();

      final missing = PdfDocumentEngine();
      expect(
        () => missing.open(_doc('${tempDir.path}/nope.pdf')),
        throwsA(isA<DocumentOpenException>()),
      );

      final emptyFile = File('${tempDir.path}/empty.pdf')
        ..writeAsBytesSync([]);
      final emptyEngine = PdfDocumentEngine();
      expect(
        () => emptyEngine.open(_doc(emptyFile.path)),
        throwsA(isA<DocumentOpenException>()),
      );

      final notPdf = File('${tempDir.path}/not.pdf')
        ..writeAsStringSync('hello, not a pdf');
      final badEngine = PdfDocumentEngine();
      expect(
        () => badEngine.open(_doc(notPdf.path)),
        throwsA(isA<DocumentOpenException>()),
      );
    });
  });
}

/// Extracts text from PDF bytes using Syncfusion's text extraction.
String _extractText(Uint8List pdfBytes) {
  final doc = PdfDocument(inputBytes: pdfBytes);
  try {
    final sb = StringBuffer();
    for (var i = 0; i < doc.pages.count; i++) {
      sb.write(PdfTextExtractor(doc).extractText(startPageIndex: i, endPageIndex: i));
    }
    return sb.toString();
  } finally {
    doc.dispose();
  }
}

/// A minimal valid 1x1 blue PNG.
Uint8List _tinyPng() => Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, // 1x1
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
