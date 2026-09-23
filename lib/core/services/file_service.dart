import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/document_file.dart';

/// Thrown when the user cancels the system file picker.
class FilePickCancelled implements Exception {
  const FilePickCancelled();
  @override
  String toString() => 'File pick cancelled';
}

/// Thrown when a document cannot be resolved to a readable local file.
class UnreadableDocumentException implements Exception {
  UnreadableDocumentException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Picks documents via the Android system document picker (SAF) and exposes
/// lightweight recent-document persistence.
class FileService {
  static const _recentKey = 'recent_documents';
  static const _maxRecent = 10;

  /// The allowed document extensions for the MVP.
  static const List<String> allowedExtensions = ['pdf', 'docx', 'xlsx', 'pptx'];

  /// Opens the system document picker filtered to supported types.
  ///
  /// Uses the SAF-backed picker (no broad storage permissions required).
  Future<DocumentFile> pickDocument() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open document',
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
    );
    if (result.isEmpty) throw const FilePickCancelled();

    final f = result.first;
    final path = f.path;
    if (path == null) {
      throw UnreadableDocumentException(
        'The selected file could not be opened on this device.',
      );
    }
    final file = File(path);
    if (!file.existsSync()) {
      throw UnreadableDocumentException(
        'The selected file is no longer accessible.',
      );
    }

    final doc = DocumentFile.fromPickedFile(
      name: f.name,
      path: path,
      uri: path,
      size: f.lengthSync(),
    );
    await addRecent(doc);
    return doc;
  }

  /// Loads recent documents (most recent first).
  Future<List<DocumentFile>> loadRecents() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_recentKey) ?? const <String>[];
      return list
          .map((s) {
            try {
              final map = jsonDecode(s);
              if (map is Map<String, dynamic>) {
                return DocumentFile.fromJson(map);
              }
              return null;
            } catch (_) {
              return null;
            }
          })
          .whereType<DocumentFile>()
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Persists a document as most recent, de-duplicating and capping the list.
  Future<void> addRecent(DocumentFile doc) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await loadRecents();
      list.removeWhere((d) => d.uri == doc.uri);
      list.insert(0, doc);
      final encoded = list
          .take(_maxRecent)
          .map((d) => jsonEncode(d.toJson()))
          .toList();
      await prefs.setStringList(_recentKey, encoded);
    } catch (_) {
      // Recents are best-effort; never break the open flow because of them.
    }
  }

  /// Removes a document from recents.
  Future<void> removeRecent(String uri) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = await loadRecents();
      list.removeWhere((d) => d.uri == uri);
      await prefs.setStringList(
        _recentKey,
        list.map((d) => jsonEncode(d.toJson())).toList(),
      );
    } catch (_) {}
  }
}
