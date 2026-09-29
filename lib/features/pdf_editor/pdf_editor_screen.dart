import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' show PdfBitmap, PdfColor;

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';
import '../../document_engines/pdf/pdf_composer.dart';
import '../../document_engines/pdf/pdf_edit_model.dart';
import '../viewer/viewer_screen.dart';

/// Dedicated PDF editor: adds/manages ONLY user-created text and images on
/// top of the unchanged original pages, then Save As into a NEW file.
///
/// The original PDF is never written to; the composed result is a new
/// document that is reopened through the existing viewer pipeline.
class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({super.key, required this.document});

  final DocumentFile document;

  static const routeName = '/pdf-editor';

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  final PdfEditorController _controller = PdfEditorController();
  final PdfPageImageRenderer _renderer = PdfPageImageRenderer();

  int _pageCount = 1;
  int _currentPage = 0;
  Uint8List? _background;
  String? _error;
  String? _selectedId;
  bool _saving = false;
  bool _pickMode = false; // waiting for a tap to place the pending element
  bool _moveMode = false; // Move button active: drag the page to move selection

  // Pending placement for Add Text / Add Image pick-mode.
  Uint8List? _pendingImageBytes;
  double _pendingAspect = 1.0;

  /// Resolved local filesystem path of the document being edited (the
  /// original stays untouched; SAF URIs are mirrored into a working copy).
  String? _localPath;

  final double _fontSize = 14;
  final PdfColor _textColor = PdfColor(0, 0, 0);
  final PdfEditTextStyle _textStyle = PdfEditTextStyle.regular;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // The document URI may be an Android SAF content:// URI — resolve it to
    // a real filesystem path (local working copy) first; never hand a
    // content URI to dart:io or the renderer.
    String localPath;
    try {
      localPath = await DocumentAccess.ensureLocalFile(
        widget.document.uri,
        widget.document.filename,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'File not found: ${widget.document.filename}');
      return;
    }
    _localPath = localPath;
    final pages = await _renderer.pageCount(localPath);
    if (!mounted) return;
    setState(() {
      _pageCount = pages ?? 1;
      _error = null;
    });
    _loadBackground();
  }

  Future<void> _loadBackground() async {
    final path = _localPath ?? widget.document.uri;
    final png = await _renderer.renderPagePng(path, _currentPage);
    if (!mounted) return;
    setState(() => _background = png);
  }

  // ------------------------------------------------------------------
  // Element operations
  // ------------------------------------------------------------------

  void _startAddText() {
    setState(() {
      _pickMode = true;
      _pendingImageBytes = null;
    });
  }

  Future<void> _startAddImage() async {
    final res = await FilePicker.pickFiles(type: FileType.image);
    if (res.isEmpty) return;
    final f = res.first;
    Uint8List? bytes;
    try {
      bytes = await f.readAsBytes();
    } catch (_) {
      bytes = null;
    }
    if (bytes == null || bytes.isEmpty) {
      _toast('Could not read the selected image.');
      return;
    }
    final aspect = _imageAspect(bytes);
    if (!mounted) return;
    setState(() {
      _pickMode = true;
      _pendingImageBytes = bytes;
      _pendingAspect = aspect;
    });
  }

  /// Image width/height, decoded via the PDF library (pure Dart), with a
  /// square fallback when decoding is unavailable.
  double _imageAspect(Uint8List bytes) {
    try {
      final bmp = PdfBitmap(bytes);
      if (bmp.height > 0) return bmp.width / bmp.height;
    } catch (_) {
      // Fall through to a square default when decoding is unavailable.
    }
    return 1.0;
  }

  void _onCanvasTapUp(TapUpDetails d, BoxConstraints box) {
    if (_pickMode) {
      final nx = (d.localPosition.dx / box.maxWidth).clamp(0.0, 1.0);
      final ny = (d.localPosition.dy / box.maxHeight).clamp(0.0, 1.0);
      final String id;
      if (_pendingImageBytes != null) {
        id = _controller.addImage(
          pageIndex: _currentPage,
          x: nx,
          y: ny,
          imageBytes: _pendingImageBytes!,
          aspect: _pendingAspect,
        );
      } else {
        id = _controller.addText(
          pageIndex: _currentPage,
          x: nx,
          y: ny,
          fontSize: _fontSize,
          color: _textColor,
          style: _textStyle,
        );
      }
      setState(() {
        _pickMode = false;
        _pendingImageBytes = null;
        _selectedId = id;
        _moveMode = false;
      });
      return;
    }
    // In Move mode a tap keeps the selection so dragging stays predictable.
    if (_moveMode) return;
    // Plain tap: selection hit-test (topmost first).
    PdfEditElement? hit;
    for (final el in _controller.elementsOnPage(_currentPage).reversed) {
      if (_hitTest(el, d.localPosition, box)) {
        hit = el;
        break;
      }
    }
    setState(() => _selectedId = hit?.id);
  }

  bool _hitTest(PdfEditElement el, Offset pos, BoxConstraints box) {
    final left = el.x * box.maxWidth;
    final top = el.y * box.maxHeight;
    final w = el.width * box.maxWidth;
    final h = el.height * box.maxHeight;
    // Text hit box is generous so short labels are easy to select.
    final hitW = el.type == PdfEditElementType.text
        ? w.clamp(80.0, box.maxWidth)
        : w;
    final hitH = el.type == PdfEditElementType.text
        ? h.clamp(28.0, box.maxHeight)
        : h;
    return pos.dx >= left &&
        pos.dx <= left + hitW &&
        pos.dy >= top &&
        pos.dy <= top + hitH;
  }

  void _onPanUpdate(DragUpdateDetails d, BoxConstraints box) {
    final el = _selected;
    if (el == null) return;
    final nx = (el.x + d.delta.dx / box.maxWidth).clamp(0.0, 1.0);
    final ny = (el.y + d.delta.dy / box.maxHeight).clamp(0.0, 1.0);
    _controller.moveElement(el.id, nx, ny);
    setState(() {});
  }

  PdfEditElement? get _selected =>
      _selectedId == null ? null : _controller.byId(_selectedId!);

  // ------------------------------------------------------------------
  // Selection property editing
  // ------------------------------------------------------------------

  Future<void> _editSelectedText() async {
    final el = _selected;
    if (el == null || el.type != PdfEditElementType.text) return;
    final controller = TextEditingController(text: el.text);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit text'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Text content',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _controller.editText(el.id, result));
  }

  Future<void> _changeFontSize() async {
    final el = _selected;
    if (el == null || el.type != PdfEditElementType.text) return;
    final controller =
        TextEditingController(text: el.fontSize.toStringAsFixed(0));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Font size'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Size (points)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text);
              Navigator.of(ctx).pop(v);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (result == null) return;
    setState(() => _controller.setFontSize(el.id, result));
  }

  Future<void> _changeTextColor() async {
    final el = _selected;
    if (el == null || el.type != PdfEditElementType.text) return;

    final palette = <Color, String>{
      Colors.black: 'Black',
      Colors.red: 'Red',
      Colors.green: 'Green',
      Colors.blue: 'Blue',
      Colors.orange: 'Orange',
      Colors.purple: 'Purple',
      Colors.brown: 'Brown',
      Colors.white: 'White',
    };
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Text color'),
        children: palette.entries
            .map((e) => SimpleDialogOption(
                  onPressed: () => Navigator.of(ctx).pop(e.key),
                  child: Row(
                    children: [
                      CircleAvatar(backgroundColor: e.key, radius: 10),
                      const SizedBox(width: 12),
                      Text(e.value),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
    if (picked == null) return;
    final mapped = _toPdfColor(picked);
    setState(() => _controller.setTextColor(el.id, mapped));
  }

  /// Converts a Flutter color to a PDF color (0..255 int channels).
  static PdfColor _toPdfColor(Color c) => PdfColor(
        (c.r * 255.0).round().clamp(0, 255),
        (c.g * 255.0).round().clamp(0, 255),
        (c.b * 255.0).round().clamp(0, 255),
      );

  void _deleteSelected() {
    final el = _selected;
    if (el == null) return;
    setState(() {
      // Removes ONLY this user-added overlay element; the original PDF
      // content is not represented in the model and is never touched.
      _controller.removeElement(el.id);
      _selectedId = null;
      _moveMode = false;
    });
    _toast('Deleted. Original PDF content is untouched.');
  }

  // ------------------------------------------------------------------
  // Save As (never overwrites the original)
  // ------------------------------------------------------------------

  Future<void> _saveAs() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final composer = PdfComposer();
      final bytes = await composer.compose(
        sourcePath: _localPath ?? widget.document.uri,
        elements: _controller.elements,
      );

      final base = widget.document.filename.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final suggestedName = '$base (edited).pdf';

      // 1) System Save As dialog: the user chooses where the edited copy
      //    goes (same pattern as the DOCX engine). Cancelling aborts.
      final uri = await FilePicker.saveFile(
        fileName: suggestedName,
        bytes: bytes,
        mimeType: 'application/pdf',
      );
      if (!mounted) return;
      if (uri == null) {
        setState(() => _saving = false);
        _toast('Save cancelled.');
        return;
      }

      // 2) App-managed generated copy: the reopen target must be a real
      //    file path (on Android the picker returns a content:// URI which
      //    flutter_pdfview cannot open). This writes a NEW file in the app
      //    documents directory; the ORIGINAL PDF is never touched.
      final docsDir = await getApplicationDocumentsDirectory();
      final localPath = '${docsDir.path}/$suggestedName';
      final localFile = File(localPath);
      if (localFile.existsSync()) localFile.deleteSync();
      localFile.writeAsBytesSync(bytes);

      final newDoc = DocumentFile.fromPickedFile(
        name: suggestedName,
        path: localPath,
        uri: localPath,
        size: bytes.length,
        mimeType: 'application/pdf',
      );

      setState(() => _saving = false);
      if (!mounted) return;
      // 3) Reopen through the EXISTING viewer pipeline.
      Navigator.of(context).pushReplacementNamed(
        ViewerScreen.routeName,
        arguments: newDoc,
      );
    } on PdfComposeException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Save failed: ${e.toString()}');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit PDF'),
        actions: [
          IconButton(
            tooltip: 'Save As',
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_as),
            onPressed: _saving ? null : _saveAs,
          ),
        ],
      ),
      body: _error != null
          ? _ErrorView(message: _error!)
          : Column(
              children: [
                _buildToolbar(),
                const Divider(height: 1),
                Expanded(child: _buildCanvas()),
                _buildSelectionPanel(),
                _buildPageBar(),
              ],
            ),
    );
  }

  Widget _buildToolbar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _pickMode ? null : _startAddText,
            icon: const Icon(Icons.text_fields),
            label: const Text('Add Text'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: _pickMode ? null : _startAddImage,
            icon: const Icon(Icons.image),
            label: const Text('Add Image'),
          ),
          if (_pickMode)
            const Padding(
              padding: EdgeInsets.only(left: 8),
              child: Text('Tap the page to place…'),
            ),
        ],
      ),
    );
  }

  /// Clearly labelled controls for the currently selected USER-ADDED
  /// element.
  ///
  /// Text: Edit text / Font size / Text color / Regular / Bold / Italic /
  /// Bold + Italic / Delete. Image: Move / Resize / Delete. Delete removes
  /// only the selected user-added element — original PDF content is never
  /// represented in the model, so it cannot be modified or deleted.
  Widget _buildSelectionPanel() {
    final sel = _selected;
    if (sel == null) return const SizedBox.shrink();

    final isText = sel.type == PdfEditElementType.text;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  isText ? 'Selected: Text' : 'Selected: Image',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton.icon(
                onPressed: () => setState(() {
                  _selectedId = null;
                  _moveMode = false;
                }),
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Deselect'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (isText) ...[
                OutlinedButton.icon(
                  onPressed: _editSelectedText,
                  icon: const Icon(Icons.edit),
                  label: const Text('Edit text'),
                ),
                OutlinedButton.icon(
                  onPressed: _changeFontSize,
                  icon: const Icon(Icons.format_size),
                  label: const Text('Font size'),
                ),
                OutlinedButton.icon(
                  onPressed: _changeTextColor,
                  icon: const Icon(Icons.palette),
                  label: const Text('Text color'),
                ),
                OutlinedButton.icon(
                  onPressed: _resizeSelected,
                  icon: const Icon(Icons.aspect_ratio),
                  label: const Text('Resize'),
                ),
              ] else ...[
                if (_moveMode)
                  FilledButton.icon(
                    onPressed: () => setState(() => _moveMode = false),
                    icon: const Icon(Icons.open_with),
                    label: const Text('Moving… tap to stop'),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: () => setState(() => _moveMode = true),
                    icon: const Icon(Icons.open_with),
                    label: const Text('Move'),
                  ),
                OutlinedButton.icon(
                  onPressed: _resizeSelected,
                  icon: const Icon(Icons.aspect_ratio),
                  label: const Text('Resize'),
                ),
              ],
              OutlinedButton.icon(
                onPressed: _deleteSelected,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(color: Theme.of(context).colorScheme.error),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete'),
              ),
            ],
          ),
          if (isText) ...[
            const SizedBox(height: 4),
            Text('Text style:', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final s in PdfEditTextStyle.values)
                  ChoiceChip(
                    label: Text(switch (s) {
                      PdfEditTextStyle.regular => 'Regular',
                      PdfEditTextStyle.bold => 'Bold',
                      PdfEditTextStyle.italic => 'Italic',
                      PdfEditTextStyle.boldItalic => 'Bold + Italic',
                    }),
                    selected: sel.textStyle == s,
                    onSelected: (_) =>
                        setState(() => _controller.setTextStyle(sel.id, s)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 2),
          Text(
            'Drag it on the page to move it. Delete removes only this '
            'added element — the original PDF is never changed.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Future<void> _resizeSelected() async {
    final el = _selected;
    if (el == null) return;
    final wCtrl =
        TextEditingController(text: (el.width * 100).toStringAsFixed(0));
    final hCtrl =
        TextEditingController(text: (el.height * 100).toStringAsFixed(0));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resize element'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: wCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Width (% of page)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Height (% of page)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final w = double.tryParse(wCtrl.text);
    final h = double.tryParse(hCtrl.text);
    if (w == null || h == null) return;
    setState(() => _controller.resizeElement(el.id, w / 100, h / 100));
  }

  Widget _buildCanvas() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _onCanvasTapUp(d, constraints),
              onPanUpdate: (d) => _onPanUpdate(d, constraints),
              child: SizedBox.expand(
                child: _background != null
                    ? Image.memory(
                        _background!,
                        fit: BoxFit.contain,
                        alignment: Alignment.topCenter,
                      )
                    : const ColoredBox(
                        color: Color(0xFFEFEFEF),
                        child: Center(child: Text('Page background')),
                      ),
              ),
            ),
            // Overlay for user-added elements of the current page.
            ..._buildElementWidgets(constraints),
            if (_saving)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.black38,
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        );
      },
    );
  }

  List<Widget> _buildElementWidgets(BoxConstraints box) {
    return _controller.elementsOnPage(_currentPage).map((el) {
      final isSelected = el.id == _selectedId;
      final left = el.x * box.maxWidth;
      final top = el.y * box.maxHeight;
      final w = el.width * box.maxWidth;
      final h = el.height * box.maxHeight;

      Widget child;
      if (el.type == PdfEditElementType.text) {
        child = Text(
          el.text,
          style: TextStyle(
            fontSize: el.fontSize,
            color: Color.fromARGB(
              255,
              el.color.r.clamp(0, 255),
              el.color.g.clamp(0, 255),
              el.color.b.clamp(0, 255),
            ),
            fontWeight: el.textStyle == PdfEditTextStyle.bold ||
                    el.textStyle == PdfEditTextStyle.boldItalic
                ? FontWeight.bold
                : FontWeight.normal,
            fontStyle: el.textStyle == PdfEditTextStyle.italic ||
                    el.textStyle == PdfEditTextStyle.boldItalic
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        );
      } else {
        final bytes = el.imageBytes;
        child = bytes == null
            ? const SizedBox()
            : Image.memory(bytes, fit: BoxFit.fill);
      }

      return Positioned(
        key: ValueKey(el.id),
        left: left,
        top: top,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selectedId = el.id),
          onPanUpdate: (d) => _onPanUpdate(d, box),
          child: Container(
            width: el.type == PdfEditElementType.text ? null : w,
            height: el.type == PdfEditElementType.text ? null : h,
            decoration: BoxDecoration(
              border: isSelected
                  ? Border.all(
                      color: _moveMode ? Colors.deepOrange : Colors.indigo,
                      width: _moveMode ? 2.5 : 1.5,
                    )
                  : null,
            ),
            child: child,
          ),
        ),
      );
    }).toList();
  }

  Widget _buildPageBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: _currentPage > 0
                ? () {
                    setState(() {
                      _currentPage--;
                      _selectedId = null;
                      _moveMode = false;
                    });
                    _loadBackground();
                  }
                : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('Page ${_currentPage + 1} / $_pageCount'),
          IconButton(
            onPressed: _currentPage < _pageCount - 1
                ? () {
                    setState(() {
                      _currentPage++;
                      _selectedId = null;
                      _moveMode = false;
                    });
                    _loadBackground();
                  }
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
