import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_router.dart';
import '../../document_engines/document_engine.dart';
import '../../document_engines/pdf/pdf_engine.dart';
import '../pdf_editor/pdf_editor_screen.dart';

/// Viewer screen: routes the document to the correct engine and hosts
/// the engine's viewer widget, plus Save/Save As/Share actions.
///
/// For inline-editing engines (DOCX) this SAME screen is also the editor:
/// the app bar flips the engine's editMode notifier — no second route is
/// ever pushed. VIEW: Back / name / Edit / Share — EDIT: Back / name /
/// Save / Share (+ Cancel).
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key, this.document});

  final DocumentFile? document;

  static const routeName = '/viewer';

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  DocumentEngine? _engine;
  bool _loading = true;
  String? _error;
  bool _started = false;
  bool _saving = false;
  bool _editMode = false;
  String? _lastSavedName;

  DocumentFile? get _document =>
      widget.document ??
      (ModalRoute.of(context)?.settings.arguments as DocumentFile?);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _init();
    }
  }

  Future<void> _init() async {
    final doc = _document;

    if (doc == null) {
      setState(() {
        _loading = false;
        _error = 'No document was provided.';
      });
      return;
    }

    if (doc.type == DocumentType.unknown) {
      setState(() {
        _loading = false;
        _error =
            'Unsupported file type: .${doc.extension.isEmpty ? '?' : doc.extension}\n'
            'Supported types: PDF, DOCX, XLSX, PPTX.';
      });
      return;
    }

    try {
      final router = DocumentRouter();
      final engine = await router.routeAndOpen(doc);
      if (!mounted) return;
      // Inline editing: the host drives the engine's mode notifier.
      if (engine is InlineEditingEngine) {
        engine.setSaveAsHandler(_saveBytesAs);
        engine.editMode.addListener(_onEngineEditModeChanged);
        _editMode = engine.editMode.value;
      }
      if (engine is PdfDocumentEngine) {
        // Wire the dedicated PDF editor through the SAME engine instance
        // that opened this document, so Edit never hits a dead instance.
        engine.setEditorOpener(_openPdfEditor);
      }
      // Restore any previously generated copy so Share offers it even
      // after the viewer/engine has been recreated.
      if (engine is InlineEditingEngine) {
        await engine.restoreLastSaved();
      }
      setState(() {
        _engine = engine;
        _loading = false;
      });
    } on UnsupportedError {
      setState(() {
        _loading = false;
        _error = 'Unsupported file type: .${doc.extension}';
      });
    } on DocumentOpenException catch (e) {
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = 'Could not open document: ${e.toString()}';
      });
    }
  }

  void _onEngineEditModeChanged() {
    final engine = _engine;
    if (engine is! InlineEditingEngine) return;
    if (!mounted) return;
    setState(() => _editMode = engine.editMode.value);
  }

  InlineEditingEngine? get _inlineEngine =>
      _engine is InlineEditingEngine ? _engine as InlineEditingEngine : null;

  void _toggleEditMode(bool editing) {
    final engine = _inlineEngine;
    if (engine == null) return;
    if (!editing && engine.isDirty) {
      _confirmDiscardThen(editing: editing);
      return;
    }
    engine.editMode.value = editing;
    setState(() => _editMode = editing);
  }

  Future<void> _confirmDiscardThen({required bool editing}) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
            'You have unsaved edits. Leave edit mode without saving?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    final engine = _inlineEngine;
    if (engine != null) engine.editMode.value = editing;
    if (mounted) setState(() => _editMode = editing);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    final canEditInline = _inlineEngine != null;
    final canSaveAs = _engine?.capabilities.canSaveAs ?? false;
    return PopScope(
      canPop: !_editMode,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmDiscardThen(editing: false);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(doc?.filename ?? 'Document'),
          actions: _appBarActions(doc, canEditInline, canSaveAs),
        ),
        body: _buildBody(doc),
      ),
    );
  }

  List<Widget> _appBarActions(
    DocumentFile? doc,
    bool canEditInline,
    bool canSaveAs,
  ) {
    if (_engine == null || doc == null) return const [];
    return [
      // VIEW MODE: Edit enters edit mode ON THE SAME SCREEN.
      if (canEditInline && !_editMode)
        IconButton(
          tooltip: 'Edit',
          icon: const Icon(Icons.edit),
          onPressed: () => _toggleEditMode(true),
        ),
      // EDIT MODE: Save exports via Save As; Cancel returns to view mode.
      if (_editMode) ...[
        IconButton(
          tooltip: 'Save',
          icon: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save),
          onPressed: _saving ? null : () => _saveInline(doc),
        ),
        IconButton(
          tooltip: 'Cancel editing',
          icon: const Icon(Icons.close),
          onPressed: () => _toggleEditMode(false),
        ),
      ],
      // VIEW MODE (non-inline engines): keep prior Save As capability.
      if (!_editMode && canSaveAs && !canEditInline)
        IconButton(
          tooltip: 'Save As',
          icon: const Icon(Icons.save_as),
          onPressed: () => _save(isSaveAs: true),
        ),
      IconButton(
        tooltip: 'Share',
        icon: const Icon(Icons.share),
        onPressed: () => _share(doc),
      ),
    ];
  }

  Widget _buildBody(DocumentFile? doc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      );
    }
    return _engine!.buildViewer(context, doc!);
  }

  /// Exports the current edited model through the engine's Save As handler
  /// (Android SAF dialog). On success: exit edit mode, stay on THIS screen,
  /// offer the saved copy for sharing.
  Future<void> _saveInline(DocumentFile doc) async {
    final engine = _inlineEngine;
    if (engine == null || _saving) return;
    setState(() => _saving = true);
    try {
      final result = await engine.saveAs(doc);
      if (!mounted) return;
      setState(() {
        _saving = false;
        if (result == SaveResult.savedAs) {
          _lastSavedName = engine.lastSavedName;
          engine.editMode.value = false; // back to view mode, same screen
        }
      });
      final message = switch (result) {
        SaveResult.savedAs => _lastSavedName != null
            ? 'Saved as $_lastSavedName'
            : 'Saved a copy.',
        SaveResult.cancelled => 'Save cancelled.',
        _ => 'Save failed.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: ${e.toString()}')),
      );
    }
  }

  /// Handler injected into inline engines: writes bytes through the SAF
  /// Save As dialog and returns the destination URI (null = cancelled).
  Future<Uri?> _saveBytesAs(
    Uint8List bytes,
    String suggestedFileName,
    String mimeType,
  ) async {
    return FilePicker.saveFile(
      fileName: suggestedFileName,
      bytes: bytes,
      mimeType: mimeType,
    );
  }

  Future<void> _save({required bool isSaveAs}) async {
    final doc = _document;
    final engine = _engine;
    if (doc == null || engine == null) return;
    try {
      final result = await (isSaveAs ? engine.saveAs(doc) : engine.save(doc));
      if (!mounted) return;
      final message = switch (result) {
        SaveResult.saved => 'Saved.',
        SaveResult.savedAs => 'Saved a copy.',
        SaveResult.cancelled => 'Save cancelled.',
        SaveResult.unsupported => 'Saving is not supported for this format.',
        SaveResult.failed => 'Save failed.',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    } on UnsupportedError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saving is not supported for this format.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Save failed: ${e.toString()}')),
      );
    }
  }

  /// Opens the dedicated PDF editor (wired into [PdfDocumentEngine]).
  void _openPdfEditor(BuildContext context, DocumentFile document) {
    Navigator.of(context).pushNamed(
      PdfEditorScreen.routeName,
      arguments: document,
    );
  }

  /// Shares the document through the ENGINE's share target: inline-edit
  /// engines (DOCX) prefer their most recently generated copy; other
  /// engines fall back to the original document location. The host never
  /// guesses where the shareable file lives.
  Future<void> _share(DocumentFile doc) async {
    final engine = _engine;
    if (engine == null) return;
    try {
      final target = await engine.shareTarget(doc);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(target.path)], text: target.name),
      );
    } on ShareUnavailableException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Share failed: ${e.toString()}')),
      );
    }
  }

  @override
  void dispose() {
    final engine = _engine;
    if (engine is InlineEditingEngine) {
      engine.editMode.removeListener(_onEngineEditModeChanged);
    }
    _engine?.dispose();
    super.dispose();
  }
}
