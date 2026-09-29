import 'package:flutter_test/flutter_test.dart';
import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/core/services/document_router.dart';
import 'package:viewerpal/document_engines/docx/docx_engine.dart';
import 'package:viewerpal/document_engines/pdf/pdf_engine.dart';
import 'package:viewerpal/document_engines/pptx/pptx_engine.dart';
import 'package:viewerpal/document_engines/xlsx/xlsx_engine.dart';

DocumentFile _doc(DocumentType type, String name) => DocumentFile(
      uri: 'content://test/$name',
      filename: name,
      extension: name.split('.').last,
      type: type,
    );

void main() {
  test('routes PDF to PdfDocumentEngine', () {
    final engine = DocumentRouter().route(_doc(DocumentType.pdf, 'a.pdf'));
    expect(engine, isA<PdfDocumentEngine>());
  });

  test('routes DOCX to DocxDocumentEngine', () {
    final engine = DocumentRouter().route(_doc(DocumentType.docx, 'a.docx'));
    expect(engine, isA<DocxDocumentEngine>());
  });

  test('routes XLSX to XlsxDocumentEngine', () {
    final engine = DocumentRouter().route(_doc(DocumentType.xlsx, 'a.xlsx'));
    expect(engine, isA<XlsxDocumentEngine>());
  });

  test('routes PPTX to PptxDocumentEngine', () {
    final engine = DocumentRouter().route(_doc(DocumentType.pptx, 'a.pptx'));
    expect(engine, isA<PptxDocumentEngine>());
  });

  test('returns null for unknown types', () {
    final engine = DocumentRouter().route(_doc(DocumentType.unknown, 'a.zip'));
    expect(engine, isNull);
  });

  test('capabilities honestly differ per engine', () {
    final router = DocumentRouter();
    // PDF: viewing + overlay annotation editor; no inline editing, no save.
    final pdf = router.route(_doc(DocumentType.pdf, 'a.pdf'))!;
    expect(pdf.capabilities.canEdit, isFalse);
    expect(pdf.capabilities.canSaveAs, isFalse);
    expect(pdf.capabilities.canAnnotate, isTrue);

    // DOCX/XLSX/PPTX: inline edit + Save As, never in-place save.
    for (final t in [DocumentType.docx, DocumentType.xlsx, DocumentType.pptx]) {
      final e = router.route(_doc(t, 'f.${t.name}'))!;
      expect(e.capabilities.canEdit, isTrue, reason: t.name);
      expect(e.capabilities.canSave, isFalse, reason: t.name);
      expect(e.capabilities.canSaveAs, isTrue, reason: t.name);
    }
  });

  test('routeAndOpen throws UnsupportedError for unknown types', () async {
    expect(
      () => DocumentRouter()
          .routeAndOpen(_doc(DocumentType.unknown, 'a.bin')),
      throwsUnsupportedError,
    );
  });
}
