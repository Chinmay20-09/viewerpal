import 'dart:io';
import 'dart:typed_data';

import 'package:docx_creator/docx_creator.dart';
import 'package:docx_file_viewer/docx_file_viewer.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/models/document_file.dart';
import '../document_engine.dart';

/// DOCX engine: parse existing .docx into a docx_creator AST, allow basic
/// text-level edits in that AST, export via DocxExporter, and Save As through
/// the Android SAF dialog. Viewing (untouched document) still uses
/// docx_file_viewer for native rendering, search and zoom.
///
/// The original file is never overwritten: only Save As is offered.
class DocxDocumentEngine extends DocumentEngine {
  DocxBuiltDocument? _document;
  bool _dirty = false;
  Uint8List? _cachedPreview;
  bool _previewStale = true;

  @override
  String get name => 'DocxDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: true,
        canSave: false, // in-place overwrite deliberately avoided in MVP
        canSaveAs: true,
      );

  Future<void> _ensureLoaded(DocumentFile document) async {
    if (_document != null) return;
    final f = File(document.uri);
    if (!f.existsSync()) {
      throw DocumentOpenException('File not found: ${document.filename}');
    }
    if (f.lengthSync() == 0) {
      throw DocumentOpenException('File is empty: ${document.filename}');
    }
    // DOCX is a ZIP; check the magic bytes (PK) for a friendly error.
    final raf = f.openSync();
    try {
      final header = raf.readSync(2);
      if (header.length < 2 || header[0] != 0x50 || header[1] != 0x4B) {
        throw DocumentOpenException(
          'This file does not look like a valid DOCX document.',
        );
      }
    } finally {
      raf.closeSync();
    }
    final bytes = await f.readAsBytes();
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
    return _DocxViewer(engine: this, document: document);
  }

  // --------------------------------------------------------------------
  // Read access to the parsed AST (used by the editor UI and tests).
  // --------------------------------------------------------------------

  /// True when a document has been parsed and is ready for edits/export.
  bool get isLoaded => _document != null;

  /// True when at least one edit has been applied since the last load.
  bool get isDirty => _dirty;

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

  /// Replaces the text of a single text run inside a paragraph.
  ///
  /// [paragraphIndex] refers to top-level [DocxParagraph] blocks in document
  /// order (same ordering as [paragraphs]).
  bool editTextRun(int paragraphIndex, int runIndex, String newText) {
    final doc = _document;
    if (doc == null) return false;
    final paragraphs =
        doc.elements.whereType<DocxParagraph>().toList(growable: false);
    if (paragraphIndex < 0 || paragraphIndex >= paragraphs.length) {
      return false;
    }
    final p = paragraphs[paragraphIndex];
    if (runIndex < 0 || runIndex >= p.children.length) return false;
    final child = p.children[runIndex];
    if (child is! DocxText) return false;

    final newChildren = List<DocxInline>.from(p.children);
    newChildren[runIndex] = child.copyWith(content: newText);
    final updated = p.copyWith(children: newChildren);
    _replaceParagraph(doc, p, updated);
    _dirty = true;
    _previewStale = true;
    return true;
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

  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    final bytes = await exportBytes();
    final base =
        document.filename.replaceAll(RegExp(r'\.docx$', caseSensitive: false), '');
    final uri = await FilePicker.saveFile(
      fileName: '$base (edited).docx',
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    );
    if (uri == null) return SaveResult.cancelled;
    return SaveResult.savedAs;
  }

  @override
  void dispose() {
    _document = null;
    _cachedPreview = null;
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
// Viewer / editor UI
// ==========================================================================

class _DocxViewer extends StatefulWidget {
  const _DocxViewer({required this.engine, required this.document});

  final DocxDocumentEngine engine;
  final DocumentFile document;

  @override
  State<_DocxViewer> createState() => _DocxViewerState();
}

class _DocxViewerState extends State<_DocxViewer> {
  bool _editMode = false;
  bool _preparingPreview = false;
  bool _hasEdits = false;

  Future<void> _toggleMode() async {
    if (_editMode) {
      // Switching to view mode: re-render from the current AST when edits
      // exist, so the preview reflects them instead of the original file.
      setState(() => _preparingPreview = true);
      try {
        await widget.engine.previewBytes();
      } catch (_) {
        // Preview is best-effort; fall back to the original file view.
        if (!mounted) return;
        setState(() => _preparingPreview = false);
      }
      if (!mounted) return;
      setState(() {
        _preparingPreview = false;
        _hasEdits = widget.engine.isDirty;
      });
    }
    setState(() => _editMode = !_editMode);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.engine.capabilities.canEdit)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                onPressed: _toggleMode,
                icon: Icon(_editMode ? Icons.visibility : Icons.edit),
                label: Text(_editMode ? 'View document' : 'Edit text'),
              ),
            ),
          ),
        Expanded(
          child: _preparingPreview
              ? const Center(child: CircularProgressIndicator())
              : _editMode
                  ? _DocxEditor(engine: widget.engine)
                  : _hasEdits
                      ? _DocxPreview(engine: widget.engine)
                      : DocxView.path(
                          widget.document.uri,
                          config: const DocxViewConfig(
                            enableSearch: true,
                            enableZoom: true,
                            pageMode: DocxPageMode.paged,
                          ),
                        ),
        ),
      ],
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

/// Minimal text editor over the parsed AST. Lists paragraphs so the user can
/// modify textual content without restructuring the document.
class _DocxEditor extends StatefulWidget {
  const _DocxEditor({required this.engine});

  final DocxDocumentEngine engine;

  @override
  State<_DocxEditor> createState() => _DocxEditorState();
}

class _DocxEditorState extends State<_DocxEditor> {
  final _controllers = <int, TextEditingController>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controllerFor(int index, String initial) {
    return _controllers.putIfAbsent(
      index,
      () => TextEditingController(text: initial),
    );
  }

  void _applyEdits() {
    final items = widget.engine.paragraphs();
    var applied = 0;
    _controllers.forEach((index, controller) {
      if (index >= 0 && index < items.length) {
        // The flat text is the concatenation of runs; writing it back
        // replaces the paragraph's text content with the edited text.
        if (controller.text != items[index].text &&
            widget.engine.editParagraphText(index, controller.text)) {
          applied++;
        }
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(applied > 0
            ? '$applied edit(s) applied. Use Save As to export.'
            : 'No changes to apply.'),
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.engine.paragraphs();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Text editing — paragraph structure and formatting are kept.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              TextButton(
                onPressed: _applyEdits,
                child: const Text('Apply'),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(child: Text('No editable text found.'))
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      child: TextField(
                        controller: _controllerFor(i, item.text),
                        maxLines: null,
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          labelText:
                              item.isHeading ? 'Heading' : 'Paragraph ${i + 1}',
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
