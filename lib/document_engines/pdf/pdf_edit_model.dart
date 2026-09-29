import 'dart:typed_data';

import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfColor;

/// The type of a user-added element in the PDF editor.
enum PdfEditElementType { text, image }

/// Text style of user-added text: regular, bold, italic, or bold+italic.
enum PdfEditTextStyle { regular, bold, italic, boldItalic }

/// A single element the user added while editing a PDF.
///
/// Only user-created elements live in this model; the original PDF content is
/// never parsed into or represented by this model, so it cannot be modified.
/// Positions/sizes use normalized page units (0..1 relative to page width /
/// height) so the model is independent of the actual page dimensions.
class PdfEditElement {
  PdfEditElement._({
    required this.id,
    required this.type,
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Unique, stable identifier of this element.
  final String id;

  /// Whether this is a text or image element.
  final PdfEditElementType type;

  /// Zero-based page index the element is placed on.
  final int pageIndex;

  /// Position of the element's top-left corner, normalized to the page.
  double x;
  double y;

  /// Size normalized to the page (width/height relative to page size).
  double width;
  double height;

  /// Text content (text elements only).
  String text = '';

  /// Font size in PDF points (text elements only).
  double fontSize = 14;

  /// Text color (text elements only).
  PdfColor color = PdfColor(0, 0, 0);

  /// Text style: regular, bold, italic or boldItalic (text elements only).
  PdfEditTextStyle textStyle = PdfEditTextStyle.regular;

  /// Encoded image bytes (PNG or JPEG; image elements only).
  Uint8List? imageBytes;
}

/// Owns the list of user-added elements and applies all editing operations.
///
/// The controller is intentionally pure Dart (no Flutter widgets, no platform
/// channels) so the editing model can be unit tested without a device.
class PdfEditorController {
  final List<PdfEditElement> _elements = [];
  int _counter = 0;

  /// All user-added elements, in insertion order (unmodifiable view).
  List<PdfEditElement> get elements => List.unmodifiable(_elements);

  /// Elements placed on [pageIndex] (0-based), in insertion order.
  List<PdfEditElement> elementsOnPage(int pageIndex) => List.unmodifiable(
        _elements.where((e) => e.pageIndex == pageIndex),
      );

  /// Number of user-added elements currently held.
  int get count => _elements.length;

  bool get isEmpty => _elements.isEmpty;

  /// Finds a user-added element by id, or null when unknown.
  PdfEditElement? byId(String id) {
    for (final e in _elements) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Adds a text element and returns its id.
  String addText({
    required int pageIndex,
    required double x,
    required double y,
    double fontSize = 14,
    PdfColor? color,
    PdfEditTextStyle style = PdfEditTextStyle.regular,
    String text = 'New text',
  }) {
    final el = PdfEditElement._(
      id: _nextId(),
      type: PdfEditElementType.text,
      pageIndex: pageIndex,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
      width: 0.30,
      height: 0.05,
    )
      ..text = text
      ..fontSize = fontSize
      ..color = color ?? PdfColor(0, 0, 0)
      ..textStyle = style;
    _elements.add(el);
    return el.id;
  }

  /// Adds an image element from encoded [imageBytes] (PNG or JPEG) and
  /// returns its id. [aspect] is imageWidth/imageHeight; it only shapes the
  /// initial box so the image is not distorted on insertion — the element
  /// stays freely resizable and movable afterwards.
  String addImage({
    required int pageIndex,
    required double x,
    required double y,
    required Uint8List imageBytes,
    double aspect = 1.0,
  }) {
    final safeAspect = aspect > 0 ? aspect : 1.0;
    final el = PdfEditElement._(
      id: _nextId(),
      type: PdfEditElementType.image,
      pageIndex: pageIndex,
      x: x.clamp(0.0, 1.0),
      y: y.clamp(0.0, 1.0),
      width: 0.25,
      height: (0.25 / safeAspect).clamp(0.01, 0.9),
    )..imageBytes = imageBytes;
    _elements.add(el);
    return el.id;
  }

  /// Edits the text content of a user-added text element.
  bool editText(String id, String newText) =>
      _mutateText(id, (el) => el.text = newText) != null;

  /// Changes the font size of a user-added text element (in points).
  bool setFontSize(String id, double size) {
    if (size <= 0) return false;
    return _mutateText(id, (el) => el.fontSize = size) != null;
  }

  /// Changes the color of a user-added text element.
  bool setTextColor(String id, PdfColor color) =>
      _mutateText(id, (el) => el.color = color) != null;

  /// Changes the style of user-added text
  /// (regular / bold / italic / boldItalic).
  bool setTextStyle(String id, PdfEditTextStyle style) =>
      _mutateText(id, (el) => el.textStyle = style) != null;

  /// Moves a user-added element to a new normalized position.
  bool moveElement(String id, double x, double y) =>
      _mutate(id, (el) {
        el.x = x.clamp(0.0, 1.0);
        el.y = y.clamp(0.0, 1.0);
      }) !=
      null;

  /// Resizes a user-added element to a new normalized box.
  bool resizeElement(String id, double width, double height) {
    if (width <= 0 || height <= 0) return false;
    return _mutate(id, (el) {
      el.width = width.clamp(0.005, 1.0);
      el.height = height.clamp(0.005, 1.0);
    }) != null;
  }

  /// Deletes a user-added element. Returns true when it existed.
  bool removeElement(String id) {
    final el = byId(id);
    if (el == null) return false;
    _elements.remove(el);
    return true;
  }

  /// Removes all user-added elements (does not touch the original PDF).
  void clear() => _elements.clear();

  PdfEditElement? _mutate(String id, void Function(PdfEditElement) f) {
    final el = byId(id);
    if (el == null) return null;
    f(el);
    return el;
  }

  PdfEditElement? _mutateText(String id, void Function(PdfEditElement) f) {
    final el = byId(id);
    if (el == null || el.type != PdfEditElementType.text) return null;
    f(el);
    return el;
  }

  String _nextId() => 'el_${_counter++}';
}
