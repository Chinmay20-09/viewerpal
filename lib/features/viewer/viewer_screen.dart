import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_router.dart';
import '../../document_engines/document_engine.dart';

/// Viewer screen: routes the document to the correct engine and hosts
/// the engine's viewer widget, plus Save/Save As/Share actions.
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
      if (mounted) {
        setState(() {
          _engine = engine;
          _loading = false;
        });
      }
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

  @override
  Widget build(BuildContext context) {
    final doc = _document;
    return Scaffold(
      appBar: AppBar(
        title: Text(doc?.filename ?? 'Document'),
        actions: [
          if (_engine != null && doc != null) ...[
            if (_engine!.capabilities.canSave)
              IconButton(
                tooltip: 'Save',
                icon: const Icon(Icons.save),
                onPressed: () => _save(isSaveAs: false),
              ),
            if (_engine!.capabilities.canSaveAs)
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
          ],
        ],
      ),
      body: _buildBody(doc),
    );
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

  Future<void> _share(DocumentFile doc) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(doc.uri)], text: doc.filename),
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
    _engine?.dispose();
    super.dispose();
  }
}
