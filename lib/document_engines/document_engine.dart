import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../core/models/document_file.dart';

/// Result of a save operation.
enum SaveResult { saved, savedAs, unsupported, failed, cancelled }

/// Capabilities a document engine advertises.
class EngineCapabilities {
  const EngineCapabilities({
    required this.canEdit,
    required this.canSave,
    required this.canSaveAs,
  });

  final bool canEdit;
  final bool canSave;
  final bool canSaveAs;
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

  /// Releases any resources held by the engine.
  void dispose();
}

/// Shared error used to signal corrupt/failed document parsing.
class DocumentOpenException implements Exception {
  DocumentOpenException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => 'DocumentOpenException: $message';
}

/// Callback that persists document bytes as a NEW file via the platform
/// Save As dialog (Android SAF), returning the destination URI or null when
/// the user cancelled.
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

  /// URI of the most recently saved copy (null when none). Prefer this when
  /// sharing the result of a Save As; it may be a local path under the app's
  /// files directory.
  String? get lastSavedUri;
}
