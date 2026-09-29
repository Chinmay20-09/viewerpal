import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';

/// Result of a save operation.
enum SaveResult { saved, savedAs, unsupported, failed, cancelled }

/// Capabilities a document engine advertises.
///
/// Each engine declares ONLY what it genuinely implements; the UI derives
/// every visible action from these flags instead of assuming a uniform
/// feature set across formats.
class EngineCapabilities {
  const EngineCapabilities({
    required this.canEdit,
    required this.canSave,
    required this.canSaveAs,
    this.canSearch = false,
    this.canAnnotate = false,
  });

  final bool canEdit;
  final bool canSave;
  final bool canSaveAs;

  /// True when the built-in viewer supports text search.
  final bool canSearch;

  /// True when the viewer supports user-added overlays/annotations
  /// (e.g. the PDF editor's text/image elements).
  final bool canAnnotate;
}

/// Base interface for format-specific document engines.
///
/// The abstraction intentionally does NOT pretend all formats have identical
/// capabilities; engines advertise what they support via [capabilities] and
/// may throw [UnsupportedError] for unsupported operations.
abstract class DocumentEngine {
  /// Human-readable engine name (for logging/debug).
  String get name;

  /// What this engine can do.
  EngineCapabilities get capabilities;

  /// Prepares the engine to view/edit the document (parse, load pages, etc).
  Future<void> open(DocumentFile document);

  /// Builds the viewer widget. [open] must have completed successfully.
  Widget buildViewer(BuildContext context, DocumentFile document);

  /// Saves modifications back to the original document.
  ///
  /// Engines that do not support in-place saving throw [UnsupportedError].
  Future<SaveResult> save(DocumentFile document);

  /// Saves the current state to a new file chosen by the user.
  ///
  /// Engines that do not support Save As throw [UnsupportedError].
  Future<SaveResult> saveAs(DocumentFile document);

  /// Prepares the document for sharing and returns its real location.
  ///
  /// Engines that only produce files through Save As (no in-place save)
  /// return their most recently saved copy here — a real local file the
  /// platform share sheet can attach. Engines without any produced artifact
  /// return the original [document] location. A successful result must
  /// always be a readable `file://`/plain path or a resolvable content URI.
  ///
  /// Throws [ShareUnavailableException] when nothing shareable currently
  /// exists (e.g. no copy has been saved yet and the original was deleted).
  Future<ShareTarget> shareTarget(DocumentFile document) async {
    final uri = document.originalUri;
    if (await DocumentAccess.isAccessible(uri)) {
      return ShareTarget(path: uri, name: document.filename);
    }
    throw ShareUnavailableException(
      '"${document.filename}" is no longer accessible. '
      'Pick it again to share it.',
    );
  }

  /// Releases any resources held by the engine.
  void dispose();
}

/// A concrete, shareable document location produced by [DocumentEngine.shareTarget].
class ShareTarget {
  const ShareTarget({required this.path, required this.name});

  /// Local filesystem path or resolvable Android content URI.
  final String path;

  /// Display/file name for the shared file.
  final String name;
}

/// Thrown by [DocumentEngine.shareTarget] when no shareable file exists.
class ShareUnavailableException implements Exception {
  const ShareUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Shared error used to signal corrupt/failed document parsing.
class DocumentOpenException implements Exception {
  DocumentOpenException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'DocumentOpenException: $message';
}

/// Callback that writes document bytes through the platform Save As dialog
/// (Android SAF), returning the destination URI or null when the user
/// cancelled. Engines additionally persist the bytes with
/// [DocumentAccess.storeLocalCopy] so the copy stays openable/shareable.
typedef SaveAsBytes = Future<Uri?> Function(
  Uint8List bytes,
  String suggestedFileName,
  String mimeType,
);

/// Contract for engines whose editing is a MODE of the existing viewer
/// (no separate editor route): one loaded in-memory model, rendered by
/// [buildViewer] in both modes; the host flips [editMode] from the app bar.
///
/// Engines expose their own reactive state (e.g. [ValueNotifier]); the host
/// listens instead of the engine reaching into host UI.
abstract class InlineEditingEngine extends DocumentEngine {
  /// Whether the host UI should render editing controls. The engine does
  /// not navigate; the HOST (ViewerScreen) owns the app bar and mode state
  /// through this notifier so both stay in sync on the SAME screen.
  ValueNotifier<bool> get editMode;

  /// True when the loaded model has unsaved modifications.
  bool get isDirty;

  /// Callback used to export bytes through the platform Save As dialog.
  /// Injected by the host so engines stay testable without plugin mocks.
  void setSaveAsHandler(SaveAsBytes handler);

  /// Name of the most recently saved copy (empty when none), for sharing it
  /// immediately after a successful Save As.
  String get lastSavedName;

  /// Best-effort restore of the last saved copy reference (e.g. after the
  /// engine was recreated), so Share can offer the generated file.
  Future<void> restoreLastSaved() async {}

  /// URI of the most recently saved copy (null when none). Prefer this when
  /// sharing the result of a Save As; it may be a local path under the app's
  /// files directory.
  String? get lastSavedUri;
}
