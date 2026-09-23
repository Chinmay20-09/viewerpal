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
