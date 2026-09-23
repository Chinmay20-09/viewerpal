import 'dart:io';

/// The supported document types in the Document Environment.
enum DocumentType { pdf, docx, xlsx, pptx, unknown }

/// MIME types mapped to document types, used as the primary detection signal.
const Map<String, DocumentType> kMimeToDocumentType = {
  'application/pdf': DocumentType.pdf,
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
      DocumentType.docx,
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet':
      DocumentType.xlsx,
  'application/vnd.openxmlformats-officedocument.presentationml.presentation':
      DocumentType.pptx,
};

/// Extensions (lowercase, no dot) mapped to document types. Used as a
/// fallback when reliable MIME information is not available.
const Map<String, DocumentType> kExtensionToDocumentType = {
  'pdf': DocumentType.pdf,
  'docx': DocumentType.docx,
  'xlsx': DocumentType.xlsx,
  'pptx': DocumentType.pptx,
};

/// A document selected or referenced in the app.
class DocumentFile {
  const DocumentFile({
    required this.uri,
    required this.filename,
    required this.extension,
    required this.type,
    this.mimeType,
    this.sizeBytes,
  });

  /// Content URI (e.g. `content://...`) or `file://`/plain path.
  final String uri;
  final String filename;
  final String extension; // lowercase, without dot
  final DocumentType type;
  final String? mimeType;
  final int? sizeBytes;

  bool get isSupported => type != DocumentType.unknown;

  /// Detects the document type preferring MIME when reliable, falling back to
  /// extension, and sniffing the file header as a last resort.
  static DocumentType detectType({
    String? mimeType,
    String? filename,
    String? path,
  }) {
    // 1) MIME is the most reliable signal when it maps to a known type.
    if (mimeType != null && mimeType.isNotEmpty) {
      final t = kMimeToDocumentType[mimeType.trim().toLowerCase()];
      if (t != null) return t;
    }

    // 2) Extension fallback (covers pickers that report generic MIME types
    //    like application/octet-stream for Office files).
    final ext = _extensionOf(filename ?? path);
    if (ext != null) {
      final t = kExtensionToDocumentType[ext];
      if (t != null) return t;
    }

    // 3) Header sniffing for extension-less content URIs.
    if (path != null) {
      final t = _sniffTypeFromFile(path);
      if (t != null) return t;
    }

    return DocumentType.unknown;
  }

  static String? _extensionOf(String? nameOrPath) {
    if (nameOrPath == null || nameOrPath.isEmpty) return null;
    final dot = nameOrPath.lastIndexOf('.');
    if (dot < 0 || dot == nameOrPath.length - 1) return null;
    return nameOrPath.substring(dot + 1).toLowerCase();
  }

  static DocumentType? _sniffTypeFromFile(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      final raf = f.openSync();
      try {
        final header = raf.readSync(8);
        // PDF: %PDF-
        if (header.length >= 5 &&
            header[0] == 0x25 &&
            header[1] == 0x50 &&
            header[2] == 0x44 &&
            header[3] == 0x46 &&
            header[4] == 0x2D) {
          return DocumentType.pdf;
        }
        // OOXML (docx/xlsx/pptx): ZIP magic PK\x03\x04 — type unknown from
        // header alone; handled by engines that inspect [Content_Types].xml.
        return null;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }

  static DocumentFile fromPickedFile({
    required String name,
    String? path,
    required String uri,
    int? size,
    String? mimeType,
  }) {
    final type = detectType(
      mimeType: mimeType,
      filename: name,
      path: path,
    );
    final ext = _extensionOf(name) ?? _extensionOf(path) ?? '';
    return DocumentFile(
      uri: uri,
      filename: name,
      extension: ext,
      type: type,
      mimeType: mimeType,
      sizeBytes: size,
    );
  }

  Map<String, dynamic> toJson() => {
        'uri': uri,
        'filename': filename,
        'extension': extension,
        'type': type.name,
        'mimeType': mimeType,
        'sizeBytes': sizeBytes,
      };

  static DocumentFile fromJson(Map<String, dynamic> json) => DocumentFile(
        uri: json['uri'] as String,
        filename: json['filename'] as String,
        extension: (json['extension'] ?? '') as String,
        type: DocumentType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => DocumentType.unknown,
        ),
        mimeType: json['mimeType'] as String?,
        sizeBytes: json['sizeBytes'] as int?,
      );

  @override
  String toString() => 'DocumentFile($filename, $type)';

  @override
  bool operator ==(Object other) =>
      other is DocumentFile && other.uri == uri && other.filename == filename;

  @override
  int get hashCode => Object.hash(uri, filename);
}
