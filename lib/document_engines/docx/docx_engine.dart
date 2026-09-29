import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:flutter/material.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';
import '../document_engine.dart';
/// DOCX engine: inline editing on the SAME viewer screen.
///
/// One document model is loaded (parse once), viewed and edited in place:
///
///   DocxDocumentEngine
///     ├── loaded document model (DocxBuiltDocument)
///     ├── buildViewer()   → view mode AND edit mode widgets (same screen)
///     └── saveAs()        → DocxExporter → bytes → SAF Save As
///
/// The parse happens ONCE in [open]; editing only mutates the in-memory
/// model. The original document is never overwritten: Save As always
/// produces `<original-name> (edited).docx`.
class DocxDocumentEngine extends InlineEditingEngine {
  DocxBuiltDocument? _document;
  bool _dirty = false;
  Uint8List? _cachedPreview;
  bool _previewStale = true;
  String? _lastSavedName;
  String? _lastSavedUri;

  final ValueNotifier<bool> _editMode = ValueNotifier<bool>(false);
  SaveAsBytes _saveAsHandler = _defaultSaveAsHandler;

  @override
  String get name => 'DocxDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: true,
        canSave: false, // in-place overwrite deliberately avoided in MVP
        canSaveAs: true,
      );

  @override
  ValueNotifier<bool> get editMode => _editMode;

  @override
  bool get isDirty => _dirty;

  @override
  String get lastSavedName => _lastSavedName ?? '';

  @override
  String? get lastSavedUri => _lastSavedUri;

  @override
  void setSaveAsHandler(SaveAsBytes handler) {
    _saveAsHandler = handler;
  }

  static Future<Uri?> _defaultSaveAsHandler(
    Uint8List bytes,
    String suggestedFileName,
    String mimeType,
  ) {
    throw UnimplementedError('No Save As handler installed');
  }

  /// Reads document bytes through [DocumentAccess], which understands both
  /// plain filesystem paths and Android SAF `content://` URIs (resolved via
  /// the content resolver — never treated as a temp path).
  Future<void> _ensureLoaded(DocumentFile document) async {
    if (_document != null) return;
    final Uint8List bytes;
    try {
      bytes = await DocumentAccess.readBytes(document.uri);
    } on DocumentAccessException catch (e) {
      // Normalize resolver failures (missing/empty/revoked URI) into the
      // engine-level open error so the viewer shows a friendly message.
      throw DocumentOpenException(e.message, e);
    }
    try {
      _document = await DocxReader.loadFromBytes(bytes);
    } catch (e) {
      throw DocumentOpenException(
        'Could not read document: ${e.toString()}',
        e,
      );
    }
  }

  @override
  Future<void> open(DocumentFile document) => _ensureLoaded(document);

  @override
  Widget buildViewer(BuildContext context, DocumentFile document) {
    return _DocxInlineEditor(engine: this, document: document);
  }

  // --------------------------------------------------------------------
  // Read access to the parsed AST (used by the editor UI and tests).
  // --------------------------------------------------------------------

  /// True when a document has been parsed and is ready for edits/export.
  bool get isLoaded => _document != null;

  /// Flat text representation of paragraphs, in document order.
  ///
  /// Only [DocxParagraph] blocks at the top level are included; runs inside
  /// tables are NOT editable in the MVP (basic text editing scope).
  List<EditableParagraph> paragraphs() {
    final doc = _document;
    if (doc == null) return const [];
    final result = <EditableParagraph>[];
    var index = 0;
    for (final node in doc.elements) {
      if (node is DocxParagraph) {
        final buf = StringBuffer();
        for (final child in node.children) {
          if (child is DocxText) buf.write(child.content);
        }
        final styleId = node.styleId;
        result.add(EditableParagraph(
          index: index,
          text: buf.toString(),
          isHeading:
              styleId != null && styleId.toLowerCase().contains('heading'),
        ));
        index++;
      }
    }
    return result;
  }

  /// Replaces the full text content of a paragraph with [newText].
  ///
  /// The first text run keeps its formatting; the remaining text runs in the
  /// paragraph are dropped (basic text replacement; paragraph structure and
  /// non-text inline content are preserved).
  bool editParagraphText(int paragraphIndex, String newText) {
    final doc = _document;
    if (doc == null) return false;
    final paragraphs =
        doc.elements.whereType<DocxParagraph>().toList(growable: false);
    if (paragraphIndex < 0 || paragraphIndex >= paragraphs.length) {
      return false;
    }
    final p = paragraphs[paragraphIndex];
    final textRuns = p.children.whereType<DocxText>().toList();
    if (textRuns.isEmpty) {
      // Empty paragraph (e.g. blank line / spacer): insert a new text run so
      // typing into it works. Paragraph-level formatting is preserved.
      if (newText.isEmpty) return false;
      final updated = p.copyWith(children: [...p.children, DocxText(newText)]);
      _replaceParagraph(doc, p, updated);
      _dirty = true;
      _previewStale = true;
      return true;
    }

    final first = textRuns.first;
    final newFirst =
        first.copyWith(content: newText.isEmpty ? ' ' : newText);
    final newChildren = <DocxInline>[];
    var replaced = false;
    for (final child in p.children) {
      if (identical(child, first)) {
        newChildren.add(newFirst);
        replaced = true;
      } else if (child is DocxText) {
        continue; // drop extra text runs when replacing whole paragraph text
      } else {
        newChildren.add(child); // keep tabs/breaks/images/etc.
      }
    }
    if (!replaced) return false;

    final updated = p.copyWith(children: newChildren);
    _replaceParagraph(doc, p, updated);
    _dirty = true;
    _previewStale = true;
    return true;
  }

  void _replaceParagraph(
    DocxBuiltDocument doc,
    DocxParagraph oldP,
    DocxParagraph newP,
  ) {
    // DocxBuiltDocument is immutable; rebuild it with the replaced node so
    // all preserved parts (styles, numbering, theme, fonts...) are kept.
    final elements = List<DocxNode>.from(doc.elements);
    final idx = elements.indexOf(oldP);
    if (idx < 0) return;
    elements[idx] = newP;
    _document = DocxBuiltDocument(
      elements: elements,
      section: doc.section,
      stylesXml: doc.stylesXml,
      numberingXml: doc.numberingXml,
      settingsXml: doc.settingsXml,
      fontTableXml: doc.fontTableXml,
      fontTableRelsXml: doc.fontTableRelsXml,
      themeXml: doc.themeXml,
      contentTypesXml: doc.contentTypesXml,
      rootRelsXml: doc.rootRelsXml,
      headerBgXml: doc.headerBgXml,
      headerBgRelsXml: doc.headerBgRelsXml,
      footnotesXml: doc.footnotesXml,
      endnotesXml: doc.endnotesXml,
      numberingRelsXml: doc.numberingRelsXml,
      numberingImages: doc.numberingImages,
      fonts: doc.fonts,
      footnotes: doc.footnotes,
      endnotes: doc.endnotes,
      theme: doc.theme,
    );
  }

  // --------------------------------------------------------------------
  // Live preview + Save As
  // --------------------------------------------------------------------

  /// Returns DOCX bytes reflecting the current (possibly edited) state.
  ///
  /// Used for the live preview: the viewer renders these bytes instead of the
  /// untouched original file. Export runs only when an edit happened since the
  /// last call; the result is cached otherwise. No files are written.
  Future<Uint8List> previewBytes() async {
    if (!_previewStale && _cachedPreview != null) return _cachedPreview!;
    final bytes = await exportBytes();
    _cachedPreview = bytes;
    _previewStale = false;
    return bytes;
  }

  /// Serializes the (possibly edited) AST back to .docx bytes.
  Future<Uint8List> exportBytes() async {
    final doc = _document;
    if (doc == null) throw StateError('Document not open');
    try {
      return await DocxExporter().exportToBytes(doc);
    } catch (e) {
      throw DocumentOpenException(
        'Document could not be encoded: ${e.toString()}',
        e,
      );
    }
  }

  @override
  Future<SaveResult> save(DocumentFile document) async {
    // Deliberately not overwriting the original file in the MVP.
    throw UnsupportedError(
      'In-place save is disabled to protect the original file. Use Save As.',
    );
  }

  /// Serializes the current model and hands the bytes to the injected
  /// Save As handler (Android SAF dialog). Cancelling keeps everything
  /// unchanged; success records the new copy so it can be shared/reopened.
  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    final bytes = await exportBytes();
    final base =
        document.filename.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '');
    final suggestedName = '$base (edited).docx';
    final uri = await _saveAsHandler(bytes, suggestedName,
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
    if (uri == null) return SaveResult.cancelled;

    final savedUri = uri.toString();
    if (DocumentAccess.isContentUri(savedUri)) {
      // The SAF destination is not a plain filesystem path: keep an
      // app-managed copy as the openable artifact for Share/reopen, while
      // remembering the content URI as the canonical destination.
      _lastSavedUri = await DocumentAccess.storeLocalCopy(
          suggestedName, bytes);
    } else {
      _lastSavedUri = savedUri;
    }
    _lastSavedName = suggestedName;
    _dirty = false;
    _previewStale = true;
    return SaveResult.savedAs;
  }

  @override
  void dispose() {
    _document = null;
    _cachedPreview = null;
    _editMode.dispose();
  }
}

/// One editable paragraph as surfaced by [DocxDocumentEngine.paragraphs].
class EditableParagraph {
  const EditableParagraph({
    required this.index,
    required this.text,
    required this.isHeading,
  });

  /// Index among top-level paragraphs (stable across edits).
  final int index;

  /// Concatenated text of all text runs in the paragraph.
  final String text;

  /// Whether the paragraph uses a heading style.
  final bool isHeading;
}

// ==========================================================================
// Inline viewer/editor — ONE widget, ONE screen, TWO modes.
//
// There is intentionally NO toggle button, NO Apply button and NO separate
// editor route: the ViewerScreen app bar drives [DocxDocumentEngine.editMode]
// and this widget reacts. View mode shows the document; edit mode shows the
// SAME content as borderless editable fields that resemble document text.
// ==========================================================================

class _DocxInlineEditor extends StatefulWidget {
  const _DocxInlineEditor({required this.engine, required this.document});

  final DocxDocumentEngine engine;
  final DocumentFile document;

  @override
  State<_DocxInlineEditor> createState() => _DocxInlineEditorState();
}

class _DocxInlineEditorState extends State<_DocxInlineEditor> {
  bool _preparingPreview = false;
  bool _hasEdits = false;
  final _controllers = <int, TextEditingController>{};
  final _scrollController = ScrollController();

  /// Resolved local filesystem path of the document (SAF content:// URIs are
  /// mirrored into a read-only working copy; the original is never touched).
  String? _localPath;

  @override
  void initState() {
    super.initState();
    widget.engine.editMode.addListener(_onEditModeChanged);
    _resolveLocalPath();
  }

  Future<void> _resolveLocalPath() async {
    try {
      final path = await DocumentAccess.ensureLocalFile(
        widget.document.uri,
        widget.document.filename,
      );
      if (!mounted) return;
      setState(() => _localPath = path);
    } catch (_) {
      // Leave _localPath null; the view shows a friendly error instead.
    }
  }

  @override
  void dispose() {
    widget.engine.editMode.removeListener(_onEditModeChanged);
    for (final c in _controllers.values) {
      c.dispose();
    }
    _scrollController.dispose();
    super.dispose();
  }

  void _onEditModeChanged() {
    if (!mounted) return;
    if (widget.engine.editMode.value) {
      // Entering edit mode: apply any live controller edits is unnecessary —
      // controllers ARE the edit state; the model is updated on change.
    } else {
      // Leaving edit mode: refresh the rendered preview when edits exist.
      _refreshPreviewIfDirty();
    }
    setState(() {});
  }

  Future<void> _refreshPreviewIfDirty() async {
    if (!widget.engine.isDirty && !_hasEdits) return;
    setState(() => _preparingPreview = true);
    try {
      await widget.engine.previewBytes();
      _hasEdits = true;
    } catch (_) {
      // Preview is best-effort; fall back to the original file view.
      if (!mounted) return;
    }
    if (!mounted) return;
    setState(() => _preparingPreview = false);
  }

  TextEditingController _controllerFor(int index, String initial) {
    return _controllers.putIfAbsent(
      index,
      () => TextEditingController(text: initial),
    );
  }

  void _onTextChanged(int index, String value) {
    // Bound directly to the loaded model — no Apply step. The parsed AST is
    // NOT re-parsed; only the affected paragraph is rewritten in memory.
    widget.engine.editParagraphText(index, value);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.engine.editMode,
      builder: (context, editing, _) {
        if (_preparingPreview) {
          return const Center(child: CircularProgressIndicator());
        }
        if (editing) {
          return _buildEditor();
        }
        if (_hasEdits) {
          return _DocxPreview(engine: widget.engine);
        }
        return _buildOriginalView();
      },
    );
  }

  Widget _buildOriginalView() {
    final path = _localPath;
    if (path == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return DocxView.path(
      path,
      config: const DocxViewConfig(
        enableSearch: true,
        enableZoom: true,
        pageMode: DocxPageMode.paged,
      ),
    );
  }

  /// Edit mode: the document content itself becomes editable. No labels, no
  /// borders — fields visually resemble the document text.
  Widget _buildEditor() {
    final items = widget.engine.paragraphs();
    if (items.isEmpty) {
      return const Center(child: Text('No editable text found.'));
    }
    final baseStyle = Theme.of(context).textTheme.bodyLarge;
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: TextField(
              controller: _controllerFor(i, item.text),
              onChanged: (v) => _onTextChanged(i, v),
              maxLines: null,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.sentences,
              style: baseStyle?.copyWith(
                fontSize: item.isHeading ? 20 : null,
                fontWeight: item.isHeading ? FontWeight.w600 : null,
                height: 1.35,
              ),
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                filled: false,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Live preview of the edited document state, rendered from in-memory bytes
/// (no file is written). Falls back to a friendly message on failure.
class _DocxPreview extends StatefulWidget {
  const _DocxPreview({required this.engine});

  final DocxDocumentEngine engine;

  @override
  State<_DocxPreview> createState() => _DocxPreviewState();
}

class _DocxPreviewState extends State<_DocxPreview> {
  late Future<Uint8List> _previewFuture;

  @override
  void initState() {
    super.initState();
    _previewFuture = widget.engine.previewBytes();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: _previewFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(
            child: Text('Preview is not available for this document.'),
          );
        }
        final bytes = snapshot.data;
        if (bytes == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return DocxView.bytes(
          bytes,
          key: ValueKey(bytes.length),
          config: const DocxViewConfig(
            enableSearch: true,
            enableZoom: true,
            pageMode: DocxPageMode.paged,
          ),
        );
      },
    );
  }
}
