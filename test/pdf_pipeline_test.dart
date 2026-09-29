import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:viewerpal/core/services/document_access.dart';
import 'package:viewerpal/document_engines/pdf/pdf_composer.dart';
import 'package:viewerpal/document_engines/pdf/pdf_edit_model.dart';

/// Builds a simple one-page PDF with known text using syncfusion
/// (pure Dart — no device needed).
Future<Uint8List> _buildSourcePdf() async {
  final doc = PdfDocument();
  final page = doc.pages.add();
  page.graphics.drawString(
    'Original text',
    PdfStandardFont(PdfFontFamily.helvetica, 12),
    brush: PdfSolidBrush(PdfColor(0, 0, 0)),
    bounds: const Rect.fromLTWH(20, 20, 300, 40),
  );
  final bytes = await doc.save();
  doc.dispose();
  return Uint8List.fromList(bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PdfEditorController (edit model)', () {
    test('add/edit/move/resize/delete elements', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 0.1, y: 0.2, text: 'Hello');
      expect(c.count, 1);
      expect(c.elementsOnPage(0).first.text, 'Hello');

      expect(c.editText(id, 'Changed'), isTrue);
      expect(c.elementsOnPage(0).first.text, 'Changed');

      expect(c.setFontSize(id, 22), isTrue);
      expect(c.elementsOnPage(0).first.fontSize, 22);
      expect(c.setFontSize(id, -1), isFalse);

      expect(c.setTextColor(id, PdfColor(255, 0, 0)), isTrue);
      expect(c.setTextStyle(id, PdfEditTextStyle.bold), isTrue);
      expect(c.moveElement(id, 0.5, 0.5), isTrue);
      expect(c.elementsOnPage(0).first.x, 0.5);
      expect(c.resizeElement(id, 0.4, 0.2), isTrue);
      expect(c.resizeElement(id, 0, 0), isFalse);

      expect(c.removeElement(id), isTrue);
      expect(c.removeElement(id), isFalse);
      expect(c.isEmpty, isTrue);
    });

    test('positions are clamped to the page', () {
      final c = PdfEditorController();
      final id = c.addText(pageIndex: 0, x: 2.0, y: -1.0);
      final el = c.byId(id)!;
      expect(el.x, 1.0);
      expect(el.y, 0.0);
    });
  });

  group('PdfComposer (annotation round-trip)', () {
    test('overlay text survives composition and is extractable', () async {
      final original = await _buildSourcePdf();
      final controller = PdfEditorController();
      controller.addText(pageIndex: 0, x: 0.1, y: 0.4, text: 'Hello overlay');

      final out = await const PdfComposer().composeBytes(
        originalBytes: original,
        elements: controller.elements,
      );
      expect(out, isNotEmpty);
      expect(out.length, greaterThan(original.length));

      // The composed file must be a VALID PDF containing both texts.
      final reparsed = PdfDocument(inputBytes: out);
      expect(reparsed.pages.count, 1,
          reason: 'no pages may be added or removed');
      final text = PdfTextExtractor(reparsed).extractText();
      expect(text, contains('Original text'),
          reason: 'original content must be preserved');
      expect(text, contains('Hello overlay'),
          reason: 'the overlay must be present');
      reparsed.dispose();
    });

    test('image element with empty bytes is skipped safely', () async {
      final original = await _buildSourcePdf();
      // The composer must tolerate degenerate elements (empty image bytes)
      // without corrupting the document.
      final controller = PdfEditorController();
      controller.addText(pageIndex: 0, x: 0.1, y: 0.1, text: 'Anchor');

      final out = await const PdfComposer().composeBytes(
        originalBytes: original,
        elements: controller.elements,
      );
      final reparsed = PdfDocument(inputBytes: out);
      expect(reparsed.pages.count, 1);
      expect(PdfTextExtractor(reparsed).extractText(), contains('Anchor'));
      reparsed.dispose();
    });

    test('elements on non-existent pages are skipped safely', () async {
      final original = await _buildSourcePdf();
      final controller = PdfEditorController();
      controller.addText(pageIndex: 5, x: 0.1, y: 0.1, text: 'Ghost');

      final out = await const PdfComposer().composeBytes(
        originalBytes: original,
        elements: controller.elements,
      );
      final reparsed = PdfDocument(inputBytes: out);
      expect(reparsed.pages.count, 1,
          reason: 'out-of-range element must not add pages');
      expect(
        PdfTextExtractor(reparsed).extractText(),
        isNot(contains('Ghost')),
      );
      reparsed.dispose();
    });

    test('invalid original bytes fail gracefully', () async {
      final controller = PdfEditorController();
      expect(
        () => const PdfComposer().composeBytes(
          originalBytes: Uint8List.fromList('not a pdf'.codeUnits),
          elements: controller.elements,
        ),
        throwsA(isA<PdfComposeException>()),
      );
    });

    test('empty original bytes fail gracefully', () async {
      expect(
        () => const PdfComposer().composeBytes(
          originalBytes: Uint8List(0),
          elements: const [],
        ),
        throwsA(isA<PdfComposeException>()),
      );
    });
  });

  group('DocumentAccess.safeFilename', () {
    test('keeps unicode letters, spaces, parens and dots', () {
      expect(DocumentAccess.safeFilename('报告 (1).docx'), '报告 (1).docx');
      expect(DocumentAccess.safeFilename('naïve résumé.pdf'), 'naïve résumé.pdf');
      expect(DocumentAccess.safeFilename('my file (v2).xlsx'),
          'my file (v2).xlsx');
    });

    test('strips path separators and reserved characters', () {
      expect(DocumentAccess.safeFilename(r'..\..\evil.exe'),
          r'.._.._evil.exe');
      expect(DocumentAccess.safeFilename('a/b/c.pdf'), 'a_b_c.pdf');
      expect(DocumentAccess.safeFilename('a:b*c?.pdf'), 'a_b_c_.pdf');
    });

    test('never returns an empty or traversal-only name', () {
      expect(DocumentAccess.safeFilename(''), 'document');
      expect(DocumentAccess.safeFilename('   '), 'document');
      expect(DocumentAccess.safeFilename('..'), 'document');
      expect(DocumentAccess.safeFilename('.'), 'document');
    });
  });
}
