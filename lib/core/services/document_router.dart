import 'dart:async';

import '../../document_engines/document_engine.dart';
import '../../document_engines/docx/docx_engine.dart';
import '../../document_engines/pdf/pdf_engine.dart';
import '../../document_engines/pptx/pptx_engine.dart';
import '../../document_engines/xlsx/xlsx_engine.dart';
import '../models/document_file.dart';

/// Routes a [DocumentFile] to the engine that handles its [DocumentType].
class DocumentRouter {
  DocumentRouter({Map<DocumentType, DocumentEngine Function()>? factories})
      : _factories = factories ?? _defaultFactories;

  final Map<DocumentType, DocumentEngine Function()> _factories;

  static final Map<DocumentType, DocumentEngine Function()> _defaultFactories =
      {
    DocumentType.pdf: () => PdfDocumentEngine(),
    DocumentType.docx: () => DocxDocumentEngine(),
    DocumentType.xlsx: () => XlsxDocumentEngine(),
    DocumentType.pptx: () => PptxDocumentEngine(),
  };

  /// Returns an engine for the document, or null when the type is unsupported.
  DocumentEngine? route(DocumentFile document) {
    final factory = _factories[document.type];
    if (factory == null) return null;
    return factory();
  }

  /// Convenience: routes and opens the document, throwing when unsupported.
  Future<DocumentEngine> routeAndOpen(DocumentFile document) async {
    final engine = route(document);
    if (engine == null) {
      throw UnsupportedError(
        'No engine available for .${document.extension} documents',
      );
    }
    await engine.open(document);
    return engine;
  }
}
