import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:syncfusion_flutter_pdf/pdf.dart';

import 'pdf_edit_model.dart';

/// Composes the edited PDF: the original document is loaded and the
/// user-added elements are drawn on top of the original pages.
///
/// The original page content is never modified; user elements are pure
/// overlays on the existing pages (no pages added, removed or reordered).
/// This class is pure Dart (no widgets, no platform channels) and is fully
/// unit-testable.
class PdfComposer {
  const PdfComposer();

  /// Loads the original PDF and applies [elements] as overlays.
  ///
  /// Throws [PdfComposeException] when the original document cannot be read
  /// or is not a valid PDF. Returns the composed PDF bytes.
  Future<Uint8List> compose({
    required String sourcePath,
    required List<PdfEditElement> elements,
  }) async {
    final f = File(sourcePath);
    if (!f.existsSync()) {
      throw PdfComposeException('Original PDF not found: $sourcePath');
    }
    final Uint8List originalBytes;
    try {
      originalBytes = f.readAsBytesSync();
    } catch (e) {
      throw PdfComposeException('Could not read the original PDF.', e);
    }
    return composeBytes(originalBytes: originalBytes, elements: elements);
  }

  /// Same as [compose] but works on raw bytes (used by tests and callers that
  /// already hold the original bytes).
  Future<Uint8List> composeBytes({
    required Uint8List originalBytes,
    required List<PdfEditElement> elements,
  }) async {
    if (originalBytes.isEmpty) {
      throw PdfComposeException('The original PDF is empty.');
    }

    final PdfDocument doc;
    try {
      doc = PdfDocument(inputBytes: originalBytes);
      // Ensure page count is materialized (also validates basic structure).
      // ignore: unnecessary_statements
      doc.pages.count;
    } catch (e) {
      throw PdfComposeException(
        'The original file is not a readable PDF document.',
        e,
      );
    }

    try {
      for (final el in elements) {
        if (el.pageIndex < 0 || el.pageIndex >= doc.pages.count) {
          // Element targets a page that does not exist; skip it rather than
          // altering the page structure of the document.
          continue;
        }
        final page = doc.pages[el.pageIndex];
        final pageSize = page.size;
        final client = page.getClientSize();
        // Use the raw page size for coordinate mapping; fall back to the
        // client size when the raw size is degenerate (0 width/height).
        final w = pageSize.width > 0 ? pageSize.width : client.width;
        final h = pageSize.height > 0 ? pageSize.height : client.height;

        final g = page.graphics;
        if (el.type == PdfEditElementType.text) {
          _drawText(g, el, w, h);
        } else if (el.imageBytes != null && el.imageBytes!.isNotEmpty) {
          _drawImage(g, el, w, h);
        }
      }

      return Uint8List.fromList(await doc.save());
    } on PdfComposeException {
      rethrow;
    } catch (e) {
      throw PdfComposeException('Composing the edited PDF failed.', e);
    } finally {
      doc.dispose();
    }
  }

  void _drawText(PdfGraphics g, PdfEditElement el, double w, double h) {
    if (el.text.trim().isEmpty) return;

    final x = el.x * w;
    final y = el.y * h;
    final style = switch (el.textStyle) {
      PdfEditTextStyle.regular => null,
      PdfEditTextStyle.bold => PdfFontStyle.bold,
      PdfEditTextStyle.italic => PdfFontStyle.italic,
      PdfEditTextStyle.boldItalic => null, // handled via multiStyle below
    };
    final PdfFont font;
    if (el.textStyle == PdfEditTextStyle.boldItalic) {
      font = PdfStandardFont(
        PdfFontFamily.helvetica,
        el.fontSize,
        multiStyle: [PdfFontStyle.bold, PdfFontStyle.italic],
      );
    } else {
      font = PdfStandardFont(PdfFontFamily.helvetica, el.fontSize, style: style);
    }

    // The model stores colors as PdfColor (0..255 int channels) already.
    final brush = PdfSolidBrush(el.color);

    // Draw at the element position. Use a generous bounds box in points so
    // long lines are not clipped by the default string bounds; wrapping is
    // intentionally not applied (one overlay = one drawn text line block).
    final boxWidth = (el.width * w) > 0 ? el.width * w : 1.0;
    final bounds = Rect.fromLTWH(x, y, boxWidth, el.fontSize * 2);
    g.drawString(el.text, font, brush: brush, bounds: bounds);
  }

  void _drawImage(PdfGraphics g, PdfEditElement el, double w, double h) {
    final bytes = el.imageBytes;
    if (bytes == null || bytes.isEmpty) return;

    final PdfImage image;
    try {
      image = PdfBitmap(bytes);
    } catch (e) {
      throw PdfComposeException('A user-added image could not be decoded.', e);
    }
    final rect = Rect.fromLTWH(
      el.x * w,
      el.y * h,
      el.width * w,
      el.height * h,
    );
    g.drawImage(image, rect);
  }
}

/// Renders pages of a PDF as PNG images for the editor's visual background.
///
/// Wraps the native pdfx renderer behind a small interface so the editor UI
/// and tests can stay platform-independent.
class PdfPageImageRenderer {
  /// Renders [pageIndex] (0-based) of the file at [path] to PNG bytes.
  ///
  /// Returns null when rendering is not possible (e.g. unsupported platform
  /// or a corrupt file) — callers fall back to a blank background.
  Future<Uint8List?> renderPagePng(String path, int pageIndex) async {
    try {
      final doc = await pdfx.PdfDocument.openFile(path);
      try {
        final page = await doc.getPage(pageIndex + 1); // pdfx is 1-based.
        try {
          final rendered = await page.render(
            width: page.width * 2, // 2x for crisp display.
            height: page.height * 2,
            format: pdfx.PdfPageImageFormat.png,
          );
          return rendered?.bytes;
        } finally {
          await page.close();
        }
      } finally {
        await doc.close();
      }
    } catch (_) {
      // Rendering is best-effort; the editor remains usable with a plain
      // background when the platform cannot render (e.g. in tests).
      return null;
    }
  }

  /// Number of pages in the PDF at [path], or null when unavailable.
  Future<int?> pageCount(String path) async {
    try {
      final doc = await pdfx.PdfDocument.openFile(path);
      try {
        return doc.pagesCount;
      } finally {
        await doc.close();
      } // pdfx closes the native document here.
    } catch (_) {
      return null;
    }
  }
}

/// Thrown when composing the edited PDF fails.
class PdfComposeException implements Exception {
  const PdfComposeException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() => 'PdfComposeException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}
