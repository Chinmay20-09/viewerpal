import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/document_file.dart';
import '../../core/services/file_service.dart';
import '../viewer/viewer_screen.dart';

/// Home screen: open documents and see recently opened files.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  static const routeName = '/';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FileService _fileService = FileService();
  List<DocumentFile> _recents = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  Future<void> _loadRecents() async {
    final recents = await _fileService.loadRecents();
    if (mounted) {
      setState(() {
        _recents = recents;
        _loading = false;
      });
    }
  }

  Future<void> _openDocument() async {
    try {
      final doc = await _fileService.pickDocument();
      if (!mounted) return;
      await Navigator.of(context).pushNamed(
        ViewerScreen.routeName,
        arguments: doc,
      );
      _loadRecents();
    } on FilePickCancelled {
      // User cancelled; nothing to do.
    } on UnreadableDocumentException catch (e) {
      _showError(e.message);
    } catch (e) {
      _showError('Could not open the document: ${e.toString()}');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red.shade700),
    );
  }

  Future<void> _openRecent(DocumentFile d) async {
    final file = File(d.uri);
    if (!file.existsSync()) {
      _showError('This file is no longer accessible.');
      await _fileService.removeRecent(d.uri);
      _loadRecents();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).pushNamed(
      ViewerScreen.routeName,
      arguments: d,
    );
    _loadRecents();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Document Environment')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                FilledButton.icon(
                  onPressed: _openDocument,
                  icon: const Icon(Icons.file_open),
                  label: const Text('Open Document'),
                ),
                const SizedBox(height: 24),
                Text(
                  'Recent documents',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (_recents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                      child: Text(
                        'No recent documents yet.\nOpen one to get started.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  ..._recents.map(
                    (d) => Card(
                      child: ListTile(
                        leading: Icon(_iconFor(d.type)),
                        iconColor: _colorFor(d.type),
                        title: Text(d.filename),
                        subtitle: Text(d.type.name.toUpperCase()),
                        onTap: () => _openRecent(d),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  IconData _iconFor(DocumentType type) => switch (type) {
        DocumentType.pdf => Icons.picture_as_pdf,
        DocumentType.docx => Icons.description,
        DocumentType.xlsx => Icons.grid_on,
        DocumentType.pptx => Icons.slideshow,
        DocumentType.unknown => Icons.insert_drive_file,
      };

  Color _colorFor(DocumentType type) => switch (type) {
        DocumentType.pdf => Colors.red,
        DocumentType.docx => Colors.blue,
        DocumentType.xlsx => Colors.green,
        DocumentType.pptx => Colors.orange,
        DocumentType.unknown => Colors.grey,
      };
}
