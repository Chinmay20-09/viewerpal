import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:mime/mime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/document_file.dart' show DocumentFile, kMimeToDocumentType;
import 'document_access.dart';

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
  /// Detection flow (single source of truth = [DocumentFile.detectType]):
  /// SAF picker → PlatformFile.name/extension → MIME via package:mime →
  /// DocumentType → DocumentRouter → engine.
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
    // platforms without SAF (desktop/test). [PlatformFile.path] is null for
    // content URIs and must never be assumed to exist.
    final contentUri = _contentUriOf(f) ?? _localPathOf(f);
    if (contentUri == null) {
      throw UnreadableDocumentException(
        'The selected file could not be opened on this device.',
      );
    }

    // MIME metadata: derived from the FILENAME via package:mime.
    // AndroidPlatformFile does NOT expose a mimeType getter, and OS pickers
    // often report generic types (application/octet-stream) anyway, so the
    // extension is the one reliable signal. lookupMimeType lowercases the
    // extension internally, so 'REPORT.PDF' and 'testing.docx' both resolve.
    // Only values that map to a supported DocumentType are kept; everything
    // else stays null and DocumentFile.detectType falls back to its own
    // extension logic.
    final rawMime = lookupMimeType(f.name);
    final mime =
        rawMime != null && kMimeToDocumentType.containsKey(rawMime.trim())
            ? rawMime.trim()
            : null;

    // The picker plugin only hands out a short-lived read grant: without a
    // persistable grant the URI becomes unreadable after an app restart (and
    // on some OEM pickers the persistable flag is missing entirely, so the
    // grant cannot be persisted at all).
    //
    // 1. Try to persist the grant → the SAF URI stays canonical.
    // 2. Otherwise, while the transient grant is still alive (the plugin just
    //    used it to mirror the bytes into its own cache copy), save the bytes
    //    into app-owned storage and make THAT local copy the document
    //    identity, keeping the SAF URI only as provenance.
    var identity = contentUri;
    String? provenance;
    if (DocumentAccess.isContentUri(contentUri)) {
      final persisted = await DocumentAccess.persistReadGrant(contentUri);
      if (!persisted) {
        try {
          final bytes = await DocumentAccess.readBytes(contentUri);
          identity = await DocumentAccess.storeLocalCopy(f.name, bytes);
        } on DocumentAccessException catch (e) {
          throw UnreadableDocumentException(e.message);
        }
        // The local copy is now the identity; the content URI is kept only
        // as provenance and must NOT be treated as a readable source.
        provenance = contentUri;
      }
    }

    final doc = DocumentFile.fromPickedFile(
      name: f.name,
      path: identity.startsWith('content://') ? null : identity,
      uri: identity,
      sourcePath: provenance ?? contentUri,
      mimeType: mime,
      size: f.lengthSync(),
    );
    await addRecent(doc);
    return doc;
  }

  /// Resolves the local path of a picked file for platforms without SAF.
  ///
  /// [PlatformFile.path] is a typed nullable getter (null for non-file URIs,
  /// e.g. Android SAF content URIs), so it is safe to read directly.
  String? _localPathOf(PlatformFile f) {
    final path = f.path;
    if (path == null || path.isEmpty) return null;
    return path.startsWith('file://') ? path : 'file://$path';
  }

  /// Extracts the canonical SAF `content://` URI from a picked file.
  ///
  /// On Android, SAF picks carry the content URI in `safHandle.uri`
  /// ([AndroidPlatformFile]); other platforms never have one and null is
  /// returned so the local path remains the identity.
  String? _contentUriOf(PlatformFile f) {
    final handle = f.safHandleOrNull;
    final uri = handle?.uri.toString();
    if (uri != null && uri.startsWith('content://')) return uri;
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

/// Extension on the shared [PlatformFile] interface that safely exposes the
/// Android SAF handle without dynamic dispatch: returns null on every other
/// platform implementation.
extension PlatformFileSaf on PlatformFile {
  /// The SAF handle for Android picks, or null elsewhere.
  AndroidSAFHandle? get safHandleOrNull {
    final f = this;
    if (f is AndroidPlatformFile) return f.safHandle;
    return null;
  }
}
