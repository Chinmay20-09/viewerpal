import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:viewerpal/core/models/document_file.dart';

void main() {
  group('DocumentFile.detectType', () {
    test('detects PDF from MIME type', () {
      expect(
        DocumentFile.detectType(mimeType: 'application/pdf'),
        DocumentType.pdf,
      );
    });

    test('detects DOCX from MIME type', () {
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        ),
        DocumentType.docx,
      );
    });

    test('detects XLSX from MIME type', () {
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        ),
        DocumentType.xlsx,
      );
    });

    test('detects PPTX from MIME type', () {
      expect(
        DocumentFile.detectType(
          mimeType:
              'application/vnd.openxmlformats-officedocument.presentationml.presentation',
        ),
        DocumentType.pptx,
      );
    });

    test('extension fallback when MIME is generic octet-stream', () {
      expect(
        DocumentFile.detectType(
          mimeType: 'application/octet-stream',
          filename: 'report.docx',
        ),
        DocumentType.docx,
      );
    });

    test('extension fallback without MIME', () {
      expect(
        DocumentFile.detectType(filename: 'budget.XLSX'),
        DocumentType.xlsx,
      );
      expect(
        DocumentFile.detectType(filename: 'deck.pptx'),
        DocumentType.pptx,
      );
    });

    test('unknown for unrecognized extension', () {
      expect(
        DocumentFile.detectType(filename: 'virus.exe'),
        DocumentType.unknown,
      );
      expect(
        DocumentFile.detectType(filename: 'noextension'),
        DocumentType.unknown,
      );
    });

    test('PDF header sniffing when no name/MIME', () {
      final f = File(
        '${Directory.systemTemp.createTempSync().path}/test.pdf',
      );
      f.writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]);
      addTearDown(() {
        try {
          f.parent.deleteSync(recursive: true);
        } catch (_) {}
      });
      expect(
        DocumentFile.detectType(path: f.path),
        DocumentType.pdf,
      );
    });

    test('fromJson round-trip preserves fields', () {
      final doc = DocumentFile.fromPickedFile(
        name: 'doc.docx',
        path: '/tmp/doc.docx',
        uri: '/tmp/doc.docx',
        size: 123,
      );
      final restored = DocumentFile.fromJson(doc.toJson());
      expect(restored.type, DocumentType.docx);
      expect(restored.filename, 'doc.docx');
      expect(restored.sizeBytes, 123);
    });
  });

  group('DocumentFile.fromPickedFile', () {
    test('builds from name and path', () {
      final doc = DocumentFile.fromPickedFile(
        name: 'Sheet.xlsx',
        path: '/x/y/Sheet.xlsx',
        uri: '/x/y/Sheet.xlsx',
      );
      expect(doc.type, DocumentType.xlsx);
      expect(doc.extension, 'xlsx');
      expect(doc.isSupported, isTrue);
    });
  });
}
