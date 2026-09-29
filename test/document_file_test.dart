import 'package:flutter_test/flutter_test.dart';
import 'package:viewerpal/core/models/document_file.dart';

void main() {
  group('DocumentType.detectType', () {
    test('detects by exact MIME', () {
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          filename: 'any.name.bin',
        ),
        DocumentType.docx,
      );
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          filename: 'any.name.bin',
        ),
        DocumentType.xlsx,
      );
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          filename: 'any.name.bin',
        ),
        DocumentType.pptx,
      );
      expect(
        DocumentFile.detectType(mimeType: 'application/pdf', filename: 'x'),
        DocumentType.pdf,
      );
    });

    test('MIME is trimmed and case-insensitive', () {
      expect(
        DocumentFile.detectType(
          mimeType: ' Application/PDF ',
          filename: 'no-extension',
        ),
        DocumentType.pdf,
      );
    });

    test('generic MIME falls back to extension', () {
      expect(
        DocumentFile.detectType(
          mimeType: 'application/octet-stream',
          filename: 'report.docx',
        ),
        DocumentType.docx,
      );
      expect(
        DocumentFile.detectType(
          mimeType: 'application/octet-stream',
          filename: 'book.PPTX',
        ),
        DocumentType.pptx,
      );
    });

    test('extension detection is case-insensitive', () {
      expect(DocumentFile.detectType(filename: 'A.PDF'), DocumentType.pdf);
      expect(DocumentFile.detectType(filename: 'b.DoCx'), DocumentType.docx);
      expect(DocumentFile.detectType(filename: 'c.XLSX'), DocumentType.xlsx);
      expect(DocumentFile.detectType(filename: 'd.pptx'), DocumentType.pptx);
    });

    test('unknown extension yields unknown type', () {
      expect(
        DocumentFile.detectType(filename: 'archive.zip'),
        DocumentType.unknown,
      );
      expect(
        DocumentFile.detectType(filename: 'no_extension'),
        DocumentType.unknown,
      );
      expect(
        DocumentFile.detectType(filename: ''),
        DocumentType.unknown,
      );
      expect(
        DocumentFile.detectType(mimeType: 'text/html', filename: 'page.html'),
        DocumentType.unknown,
      );
    });
  });

  group('DocumentFile JSON round-trip', () {
    test('preserves all fields', () {
      const doc = DocumentFile(
        uri: 'content://docs/report.docx',
        filename: 'report.docx',
        extension: 'docx',
        type: DocumentType.docx,
        sizeBytes: 1234,
        sourcePath: 'content://docs/report.docx',
      );
      final restored = DocumentFile.fromJson(doc.toJson());
      expect(restored.uri, doc.uri);
      expect(restored.filename, doc.filename);
      expect(restored.type, doc.type);
      expect(restored.sizeBytes, doc.sizeBytes);
      expect(restored.sourcePath, doc.sourcePath);
    });

    test('tolerates unknown type values from older versions', () {
      final restored = DocumentFile.fromJson({
        'uri': 'file:///tmp/x.pdf',
        'filename': 'x.pdf',
        'extension': 'pdf',
        'type': 'something_new',
      });
      expect(restored.type, DocumentType.unknown);
      expect(restored.isSupported, isFalse);
    });
  });

  group('DocumentFile.originalUri', () {
    test('prefers a SAF content URI from sourcePath', () {
      const doc = DocumentFile(
        uri: '/cache/working-copy.pdf',
        filename: 'a.pdf',
        extension: 'pdf',
        type: DocumentType.pdf,
        sourcePath: 'content://ms/downloads/a.pdf',
      );
      expect(doc.originalUri, 'content://ms/downloads/a.pdf');
    });

    test('falls back to uri when sourcePath is not a content URI', () {
      const doc = DocumentFile(
        uri: 'file:///docs/saved.docx',
        filename: 'saved.docx',
        extension: 'docx',
        type: DocumentType.docx,
        sourcePath: '/cache/thing',
      );
      expect(doc.originalUri, 'file:///docs/saved.docx');
    });
  });
}
