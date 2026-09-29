import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';
import '../../features/pdf_editor/pdf_editor_screen.dart';
import '../document_engine.dart';

/// Callback used to launch the dedicated PDF editor for [document].
/// Injected by the host so the engine stays decoupled from navigation.
typedef OpenPdfEditor = void Function(BuildContext context, DocumentFile document);

/// PDF engine using the native Android PDFView.
///
/// Viewing is fully supported. Editing is provided by a dedicated editor
/// ([PdfEditorScreen]) that manages ONLY user-added text/images and writes
/// the result to a NEW file via Save As; the original file stays untouched
class PdfDocumentEngine extends DocumentEngine {
  @override
  String get name => 'PdfDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: false, // existing PDF content cannot be rewritten
        canSave: false,
        canSaveAs: false, // Save As happens inside the dedicated editor
        canSearch: false, // no text search in the MVP viewer
        canAnnotate: true, // user-added text/image overlays via the editor
      );

  /// Installed by the host: launches the dedicated PDF editor.
  OpenPdfEditor? _editorOpener;

  /// Registers the callback that opens the dedicated PDF editor for a
  /// document. The host wires this so the engine does not navigate on its
  /// own (and so tests can stub it).
  void setEditorOpener(OpenPdfEditor opener) {
    _editorOpener = opener;
  }

  @override
  Future<void> open(DocumentFile document) async {
    if (DocumentAccess.isLocalPath(document.uri)) {
      // Local file: validate as below.
      final path =
          document.uri.startsWith('file://')
              ? Uri.parse(document.uri).toFilePath()
              : document.uri;
      final f = File(path);
      if (!f.existsSync()) {
        throw DocumentOpenException('File not found: ${document.filename}');
      }
      if (f.lengthSync() == 0) {
        throw DocumentOpenException('File is empty: ${document.filename}');
      }
      // Light header validation; real rendering happens in the native view.
      final raf = f.openSync();
      try {
        final header = raf.readSync(5);
        final isPdf = header.length == 5 &&
            header[0] == 0x25 && // %
            header[1] == 0x50 && // P
            header[2] == 0x44 && // D
            header[3] == 0x46 && // F
            header[4] == 0x2D; // -
        if (!isPdf) {
          throw DocumentOpenException(
            'This file does not look like a valid PDF document.',
          );
        }
      } finally {
        raf.closeSync();
      }
      return;
    }
    if (DocumentAccess.isContentUri(document.uri)) {
      // SAF content URI: read via the content resolver; the header check
      // doubles as an accessibility probe.
      final bytes = await DocumentAccess.readBytes(document.uri);
      if (bytes.length < 5 ||
          bytes[0] != 0x25 ||
          bytes[1] != 0x50 ||
          bytes[2] != 0x44 ||
          bytes[3] != 0x46 ||
          bytes[4] != 0x2D) {
        throw DocumentOpenException(
          'This file does not look like a valid PDF document.',
        );
      }
      return;
    }
    throw DocumentOpenException(
      'This document location is not supported on this platform.',
    );
  }

  @override
  Widget buildViewer(BuildContext context, DocumentFile document) {
    return _PdfViewer(engine: this, document: document);
  }

  /// Resolves a real filesystem path for the native PDF view. SAF content
  /// URIs are mirrored into a local working copy (original stays untouched
  /// and remains the canonical source).
  Future<String> resolveLocalPath(DocumentFile document) async {
    return DocumentAccess.ensureLocalFile(document.uri, document.filename);
  }

  /// Opens the dedicated PDF editor for this document.
  ///
  /// Kept as a small, additive entry point so the existing viewer and the
  /// DocumentEngine/ViewerScreen contracts remain unchanged. The callback
  /// must be installed via [setEditorOpener] by the host; without it this
  /// is a no-op (the FAB stays functional through the host-installed
  /// callback instead of a dead engine instance).
  void openEditor(BuildContext context, DocumentFile document) {
    final opener = _editorOpener;
    if (opener != null) {
      opener(context, document);
    } else {
      Navigator.of(context).pushNamed(PdfEditorScreen.routeName,
          arguments: document);
    }
  }

  @override
  Future<SaveResult> save(DocumentFile document) async {
    throw UnsupportedError('PDF editing/saving is not supported in the MVP.');
  }

  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    throw UnsupportedError('PDF editing/saving is not supported in the MVP.');
  }

  @override
  void dispose() {}
}

class _PdfViewer extends StatefulWidget {
  const _PdfViewer({required this.engine, required this.document});

  final PdfDocumentEngine engine;
  final DocumentFile document;

  @override
  State<_PdfViewer> createState() => _PdfViewerState();
}

class _PdfViewerState extends State<_PdfViewer> {
  int? _pages;
  int _currentPage = 0;
  String? _error;
  String? _localPath;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final path = await widget.engine.resolveLocalPath(widget.document);
      if (!mounted) return;
      setState(() => _localPath = path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null || _localPath == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error != null
                ? 'Could not render PDF.\n$_error'
                : 'Loading document…',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return Stack(
      children: [
        PDFView(
          filePath: _localPath,
          enableSwipe: true,
          swipeHorizontal: false,
          autoSpacing: true,
          pageFling: true,
          onError: (error) => setState(() => _error = error.toString()),
          onPageError: (page, error) =>
              setState(() => _error = 'page $page: $error'),
          onRender: (pages) => setState(() => _pages = pages),
          onPageChanged: (page, total) {
            if (page != null) setState(() => _currentPage = page);
          },
        ),
        if (_pages == null) const Center(child: CircularProgressIndicator()),
        if (_pages != null)
          Positioned(
            bottom: 12,
            left: 0,
            right: 0,
            child: Center(
              child: Material(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text(
                    'Page ${_currentPage + 1} / $_pages',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        // Additive entry point to the dedicated PDF editor; the existing
        // viewer behavior (PDFView, page indicator) is untouched. Uses the
        // SAME engine instance that opened this document (not a fresh one,
        // which previously lost state and skipped editor wiring).
        Positioned(
          right: 16,
          bottom: 56,
          child: FloatingActionButton.extended(
            heroTag: 'pdf_edit_fab',
            tooltip: 'Edit PDF',
            icon: const Icon(Icons.edit),
            label: const Text('Edit'),
            onPressed: () =>
                widget.engine.openEditor(context, widget.document),
          ),
        ),
      ],
    );
  }
}
