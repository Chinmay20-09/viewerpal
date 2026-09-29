import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/document_file.dart' show DocumentFile, kMimeToDocumentType;

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
  /// Uses the SAF-backed picker (no storage permissions required) with a
  /// *lifetime* read grant so the returned `content://` URI can be persisted
  /// (and re-opened later from Recents).
  ///
  /// The plugin always mirrors the picked bytes into a cache copy; that copy
  /// is EPHEMERAL and is never persisted as the document identity. The SAF
  /// `content://` URI is stored instead ([DocumentFile.sourcePath]).
  Future<DocumentFile> pickDocument() async {
    final result = await FilePicker.pickFiles(
      dialogTitle: 'Open document',
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      androidOptions: FilePickerAndroidOptions(
        safOptions: AndroidSAFOptions(
          grant: AndroidSAFGrant.lifetime,
          accessMode: AndroidSAFAccessMode.readOnly,
          persistGrant: true,
        ),
      ),
    );
    if (result.isEmpty) throw const FilePickCancelled();

    final f = result.first;
    // Prefer the SAF content URI as identity; fall back to a local path on
    // platforms without SAF (desktop/test). size: null because lengthSync()
    // reports the cache-copy size, which may already be stale.
    final contentUri = _contentUriOf(f) ?? _localPathOf(f);
    if (contentUri == null) {
      throw UnreadableDocumentException(
        'The selected file could not be opened on this device.',
      );
    }

    // MIME detection: the Android picker may report a generic type such as
    // application/octet-stream, which would push detection to the
    // extension/header fallbacks. Only pass through MIME values that the
    // app actually understands; anything else is intentionally ignored.
    final rawMime = (f as dynamic).mimeType as String?;
    final mime =
        rawMime != null && kMimeToDocumentType.containsKey(rawMime.trim().toLowerCase())
            ? rawMime
            : null;

    final doc = DocumentFile.fromPickedFile(
      name: f.name,
      path: contentUri.startsWith('content://') ? null : contentUri,
      uri: contentUri,
      sourcePath: contentUri,
      mimeType: mime,
      size: null,
    );
    await addRecent(doc);
    return doc;
  }

  /// Resolves the local path of a picked file for platforms without SAF.
  String? _localPathOf(Object f) {
    final path = (f as dynamic).path as String?;
    if (path == null || path.isEmpty) return null;
    return path.startsWith('file://') ? path : 'file://$path';
  }

  /// Extracts the canonical SAF `content://` URI from a picked file.
  ///
  /// Returns null when the platform does not provide one (desktop/test),
  /// in which case the local path remains the identity.
  String? _contentUriOf(Object f) {
    // AndroidPlatformFile exposes safHandle.uri for SAF picks; accessed via
    // dynamic members to avoid a hard compile-time dependency shape while
    // still working with the concrete Android implementation.
    try {
      final handle = (f as dynamic).safHandle;
      final uri = handle?.uri?.toString();
      if (uri != null && uri.startsWith('content://')) return uri;
    } catch (_) {
      // Not the Android implementation.
    }
    // Fallback: the plugin sometimes reports the content URI directly as the
    // identifier/uri string.
    try {
      final raw = (f as dynamic).uri?.toString();
      if (raw != null && raw.startsWith('content://')) return raw;
    } catch (_) {
      // Property missing on this platform implementation.
    }
    return null;
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
