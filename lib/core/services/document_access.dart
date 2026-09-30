import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Thrown when a document URI (SAF content URI or filesystem path) can no
/// longer be resolved to readable bytes — e.g. a revoked/stale SAF grant, a
/// deleted file, or a missing local working copy.
class DocumentAccessException implements Exception {
  DocumentAccessException(this.message, [this.cause]);
  final String message;
  final Object? cause;
  @override
  String toString() => message;
}

/// Resolves a [DocumentFile.uri] to actual bytes.
///
/// Two resolution strategies, tried in order:
/// 1. Local path (`file://` or plain path) — plain filesystem read.
/// 2. Android SAF `content://` URI — read via the platform content resolver
///    through a small app-owned method channel (picks up both live picks and
///    persisted grants restored after app restarts).
///
/// Never assumes a `content://` URI is a filesystem path.
class DocumentAccess {
  DocumentAccess();

  static const _channel = MethodChannel('viewerpal/document_access');

  /// Cached local working copies, keyed by the original URI they mirror.
  /// The ORIGINAL document is never modified; these are read-only mirrors
  /// used by viewers that require real filesystem paths.
  static final Map<String, String> _localCopies = {};

  /// True when [uri] looks like a local filesystem path.
  ///
  /// Anything with a non-file, non-content scheme (e.g. a custom scheme
  /// returned by a picker on another platform) is NOT a local path and must
  /// not be handed to dart:io.
  static bool isLocalPath(String uri) {
    if (uri.startsWith('file://')) return true;
    if (uri.startsWith('content://')) return false;
    return !uri.contains('://');
  }

  /// True when [uri] is an Android SAF content URI.
  static bool isContentUri(String uri) => uri.startsWith('content://');

  /// Takes a persistable read grant on a picked SAF `content://` URI so it
  /// stays readable across activity restarts. Returns false when the
  /// provider does not offer persistable grants (or the call is unsupported
  /// on this platform), in which case the caller should cache a local copy.
  static Future<bool> persistReadGrant(String uri) async {
    if (!isContentUri(uri)) return true; // local paths need no grant
    try {
      final ok = await _channel.invokeMethod<bool>('persistUri', {
        'uri': uri,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Reads the full bytes of a document, local or SAF-backed.
  static Future<Uint8List> readBytes(String uri) async {
    if (isLocalPath(uri)) {
      final f = File(uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri);
      if (!f.existsSync()) {
        throw DocumentAccessException('File is no longer accessible.');
      }
      if (f.lengthSync() == 0) {
        throw DocumentAccessException('File is empty.');
      }
      return f.readAsBytes();
    }
    // SAF content URI.
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {
        'uri': uri,
      });
      if (bytes == null || bytes.isEmpty) {
        throw DocumentAccessException(
          'File is no longer accessible. Its access permission may have '
          'been revoked.',
        );
      }
      return bytes;
    } on DocumentAccessException {
      rethrow;
    } on PlatformException catch (e) {
      throw DocumentAccessException(
        'File is no longer accessible. Its access permission may have been '
        'revoked, or the file was moved or deleted.',
        e,
      );
    } on MissingPluginException catch (e) {
      throw DocumentAccessException(
        'This document cannot be opened on this platform.',
        e,
      );
    }
  }

  /// Returns true when the document can currently be resolved to bytes
  /// (used to show a clear message instead of crashing on stale recents).
  static Future<bool> isAccessible(String uri) async {
    try {
      final bytes = await readBytes(uri);
      return bytes.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Sanitizes a filename into a safe single-path-segment name.
  ///
  /// Keeps Unicode letters/digits (so e.g. '报告 (1).docx' stays readable),
  /// plus dots, dashes, spaces and parentheses; replaces path separators and
  /// control characters, and collapses anything else to '_'. Empty results
  /// fall back to 'document' (extension must be re-appended by the caller).
  static String safeFilename(String filename) {
    var name = filename.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    name = name.trim();
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'document';
    }
    return name;
  }

  /// Ensures a real filesystem path exists for viewers that need one
  /// (e.g. the native PDF view). For local documents this is a no-op; for
  /// SAF content URIs it creates a local READ-ONLY working copy in the app
  /// cache directory and returns its path.
  ///
  /// The original content URI remains the canonical source — the copy is
  /// only a mirror for display and can be recreated at any time.
  static Future<String> ensureLocalFile(String uri, String filename) async {
    if (isLocalPath(uri)) {
      final f = File(uri.startsWith('file://') ? Uri.parse(uri).toFilePath() : uri);
      if (!f.existsSync()) {
        throw DocumentAccessException('File is no longer accessible.');
      }
      return f.path;
    }

    final cached = _localCopies[uri];
    if (cached != null && File(cached).existsSync()) return cached;

    final bytes = await readBytes(uri);
    final dir = await _cacheDir();
    final safeName = safeFilename(filename);
    // Collisions between distinct URIs with the same display name must not
    // make one document mirror another: disambiguate with a short hash.
    var path = '$dir/$safeName';
    if (File(path).existsSync() && _localCopies.containsValue(path)) {
      final tag = uri.hashCode.toUnsigned(24).toRadixString(36);
      final dot = safeName.lastIndexOf('.');
      path = dot > 0
          ? '$dir/${safeName.substring(0, dot)}_$tag${safeName.substring(dot)}'
          : '$dir/${safeName}_$tag';
    }
    final f = File(path);
    f.writeAsBytesSync(bytes, flush: true);
    _localCopies[uri] = path;
    return path;
  }

  /// Stores an app-managed copy (e.g. a Save As result that must remain
  /// openable without any SAF grant) and returns its local path.
  ///
  /// An existing file with the same name is overwritten IN FULL with the
  /// new bytes (never appended to), so a saved copy never mixes content
  /// from a previous save of the same name.
  static Future<String> storeLocalCopy(String filename, Uint8List bytes) async {
    final base = await _appFilesDir();
    final safeName = safeFilename(filename);
    final path = '$base/$safeName';
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
    f.writeAsBytesSync(bytes, flush: true);
    return path;
  }

  static Future<String> _cacheDir() async {
    final dir = await getTemporaryDirectoryPath();
    Directory(dir).createSync(recursive: true);
    return dir;
  }

  /// Temporary directory without pulling in path_provider's plugin
  /// registration requirements for tests: uses the platform channel when
  /// available, falls back to the system temp dir.
  static Future<String> getTemporaryDirectoryPath() async {
    try {
      final result = await _channel
          .invokeMethod<String>('tempDir')
          .timeout(const Duration(seconds: 2));
      if (result != null && result.isNotEmpty) return result;
    } catch (_) {
      // Fall through to the dart:io default.
    }
    return Directory.systemTemp.path;
  }

  /// App files directory for persistent local copies. Uses the platform
  /// channel when available; falls back to a folder in the system temp dir
  /// (desktop/test), which is still a valid filesystem location.
  static Future<String> _appFilesDir() async {
    try {
      final result = await _channel
          .invokeMethod<String>('appFilesDir')
          .timeout(const Duration(seconds: 2));
      if (result != null && result.isNotEmpty) {
        Directory(result).createSync(recursive: true);
        return result;
      }
    } catch (_) {
      // Fall through to the dart:io default.
    }
    final base = '${Directory.systemTemp.path}/viewerpal_saved_copies';
    Directory(base).createSync(recursive: true);
    return base;
  }

  /// Test-only: clears the cached local working copies.
  static void clearLocalCopyCache() => _localCopies.clear();
}
