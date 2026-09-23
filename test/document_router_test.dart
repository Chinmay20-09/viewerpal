import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/core/services/document_router.dart';
import 'package:viewerpal/document_engines/document_engine.dart';
import 'package:viewerpal/document_engines/docx/docx_engine.dart';
import 'package:viewerpal/document_engines/pdf/pdf_engine.dart';
import 'package:viewerpal/document_engines/pptx/pptx_engine.dart';
import 'package:viewerpal/document_engines/xlsx/xlsx_engine.dart';

DocumentFile _doc(DocumentType type, String name) => DocumentFile(
      uri: '/tmp/$name',
      filename: name,
      extension: name.split('.').last,
      type: type,
    );

void main() {
  group('DocumentRouter', () {
    test('routes PDF to PdfDocumentEngine', () {
      final router = DocumentRouter();
      expect(
        router.route(_doc(DocumentType.pdf, 'a.pdf')),
        isA<PdfDocumentEngine>(),
      );
    });

    test('routes DOCX to DocxDocumentEngine', () {
      final router = DocumentRouter();
      expect(
        router.route(_doc(DocumentType.docx, 'a.docx')),
        isA<DocxDocumentEngine>(),
      );
    });

    test('routes XLSX to XlsxDocumentEngine', () {
      final router = DocumentRouter();
      expect(
        router.route(_doc(DocumentType.xlsx, 'a.xlsx')),
        isA<XlsxDocumentEngine>(),
      );
    });

    test('routes PPTX to PptxDocumentEngine', () {
      final router = DocumentRouter();
      expect(
        router.route(_doc(DocumentType.pptx, 'a.pptx')),
        isA<PptxDocumentEngine>(),
      );
    });

    test('returns null and throws for unknown type', () {
      final router = DocumentRouter();
      final doc = _doc(DocumentType.unknown, 'a.exe');
      expect(router.route(doc), isNull);
      expect(
        () => router.routeAndOpen(doc),
        throwsUnsupportedError,
      );
    });

    test('supports custom factory injection (mock engines)', () {
      final router = DocumentRouter(factories: {
        DocumentType.pdf: () => _FakeEngine(),
      });
      expect(
        router.route(_doc(DocumentType.pdf, 'a.pdf')),
        isA<_FakeEngine>(),
      );
    });

    test('routeAndOpen calls engine.open', () async {
      final engine = _FakeEngine();
      final router = DocumentRouter(factories: {
        DocumentType.docx: () => engine,
      });
      final doc = _doc(DocumentType.docx, 'a.docx');
      final opened = await router.routeAndOpen(doc);
      expect(identical(opened, engine), isTrue);
      expect(engine.openedWith, doc);
    });
  });
}

class _FakeEngine extends DocumentEngine {
  DocumentFile? openedWith;

  @override
  String get name => 'FakeEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: false,
        canSave: false,
        canSaveAs: false,
      );

  @override
  Future<void> open(DocumentFile document) async {
    openedWith = document;
  }

  @override
  Widget buildViewer(BuildContext context, DocumentFile document) =>
      const SizedBox.shrink();

  @override
  Future<SaveResult> save(DocumentFile document) async =>
      SaveResult.unsupported;

  @override
  Future<SaveResult> saveAs(DocumentFile document) async =>
      SaveResult.unsupported;

  @override
  void dispose() {}
}
