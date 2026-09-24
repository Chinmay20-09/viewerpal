import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';
import '../document_engine.dart';

/// A single slide's extracted text content.
class PptxSlide {
  const PptxSlide({required this.index, required this.texts});
  final int index; // 1-based slide number from the file name
  final List<String> texts;

  String get title => texts.isNotEmpty ? texts.first : 'Slide $index';
}

/// Extracted PPTX content.
class PptxDocument {
  const PptxDocument({required this.slides});
  final List<PptxSlide> slides;
}

/// PPTX engine: offline extraction of slide text from the OOXML package,
/// basic text-level editing, and Save As into a NEW .pptx file.
///
/// Viewing shows slide text (title + bullets) with a slide navigator.
/// Editing replaces paragraph text in-place inside the affected slide XML;
/// slide structure, layouts, images and every other package part are
/// preserved unchanged, and the original file is never overwritten
/// (Save As only, same policy as the DOCX engine).
/// Full slide visual rendering (shapes/images/animations) remains P3 scope.
class PptxDocumentEngine extends DocumentEngine {
  PptxDocument? _doc;
  Uint8List? _originalBytes;
  final Map<String, String> _edits = {}; // '<slidePos>:<paraIdx>' -> text
  bool _dirty = false;

  @override
  String get name => 'PptxDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: true,
        canSave: false, // in-place overwrite deliberately avoided
        canSaveAs: true,
      );

  @override
  Future<void> open(DocumentFile document) async {
    final f = File(document.uri);
    if (!f.existsSync()) {
      throw DocumentOpenException('File not found: ${document.filename}');
    }
    final bytes = await f.readAsBytes();
    if (bytes.isEmpty) {
      throw DocumentOpenException('File is empty: ${document.filename}');
    }
    try {
      _doc = PptxParser.parse(bytes);
      _originalBytes = bytes;
      _edits.clear();
      _dirty = false;
    } on ArchiveException catch (e) {
      throw DocumentOpenException(
        'This file does not look like a valid PPTX document.',
        e,
      );
    } catch (e) {
      throw DocumentOpenException(
        'Could not read presentation: ${e.toString()}',
        e,
      );
    }
  }

  @override
  Widget buildViewer(BuildContext context, DocumentFile document) {
    final doc = _doc;
    if (doc == null || doc.slides.isEmpty) {
      return const Center(child: Text('No slides found in this presentation.'));
    }
    return _PptxViewer(engine: this);
  }

  // --------------------------------------------------------------------
  // Read access to the parsed document (used by the viewer/editor UI).
  // --------------------------------------------------------------------

  /// The parsed presentation, or null before a successful [open].
  PptxDocument? get document => _doc;

  /// True when at least one edit has been applied since the last load.
  bool get isDirty => _dirty;

  /// Text paragraphs of the slide at position [slideIndex] (0-based, same
  /// order the slide navigator uses). Empty when out of range.
  List<String> slideTexts(int slideIndex) {
    final doc = _doc;
    if (doc == null || slideIndex < 0 || slideIndex >= doc.slides.length) {
      return const [];
    }
    return doc.slides[slideIndex].texts;
  }

  /// Replaces the text of one paragraph of one slide.
  ///
  /// [slideIndex] is the position in the parsed slide list; [paragraphIndex]
  /// selects among that slide's non-empty paragraphs in document order (the
  /// same order as [PptxSlide.texts]). The edit is applied in memory
  /// immediately and persisted on the next [exportBytes] / [saveAs].
  bool editSlideText(int slideIndex, int paragraphIndex, String newText) {
    final doc = _doc;
    if (doc == null) return false;
    if (slideIndex < 0 || slideIndex >= doc.slides.length) return false;
    final texts = doc.slides[slideIndex].texts;
    if (paragraphIndex < 0 || paragraphIndex >= texts.length) return false;

    _edits['$slideIndex:$paragraphIndex'] = newText;
    _dirty = true;

    // Reflect the edit in the parsed document immediately.
    final slides = List<PptxSlide>.from(doc.slides);
    final slide = slides[slideIndex];
    final newSlideTexts = [...slide.texts];
    newSlideTexts[paragraphIndex] = newText;
    slides[slideIndex] = PptxSlide(index: slide.index, texts: newSlideTexts);
    _doc = PptxDocument(slides: slides);
    return true;
  }

  // --------------------------------------------------------------------
  // Export + Save As
  // --------------------------------------------------------------------

  /// Serializes the (possibly edited) presentation back to .pptx bytes.
  ///
  /// Slide XMLs that received edits are rewritten with the replaced
  /// paragraph text; every other package part is copied byte-for-byte, so
  /// layouts, images, theme and slide structure survive exactly as they
  /// were. With no pending edits the original bytes are returned unchanged.
  Future<Uint8List> exportBytes() async {
    final doc = _doc;
    final original = _originalBytes;
    if (doc == null || original == null) {
      throw StateError('Document not open');
    }
    if (_edits.isEmpty) return Uint8List.fromList(original);

    try {
      final archive = ZipDecoder().decodeBytes(original);

      // Group pending edits by slide file name.
      final editsByFile = <String, Map<int, String>>{};
      _edits.forEach((key, text) {
        final parts = key.split(':');
        final slidePos = int.parse(parts[0]);
        final paraIdx = int.parse(parts[1]);
        final number = doc.slides[slidePos].index;
        editsByFile
            .putIfAbsent('ppt/slides/slide$number.xml', () => {})[paraIdx] =
            text;
      });

      final out = Archive();
      for (final f in archive.files) {
        if (f.isDirectory) continue;
        final data = f.readBytes() ?? Uint8List(0);
        final edits = editsByFile[f.name];
        if (edits == null) {
          // Untouched part: copied as-is.
          out.add(ArchiveFile.bytes(f.name, data));
          continue;
        }
        final xmlDoc = XmlDocument.parse(utf8.decode(data));
        // Same enumeration the parser uses: non-empty paragraphs in
        // document order, so indices match PptxSlide.texts exactly.
        final paragraphs = xmlDoc
            .findAllElements('a:p')
            .where((p) => p.innerText.trim().isNotEmpty)
            .toList();
        edits.forEach((paraIdx, text) {
          if (paraIdx >= 0 && paraIdx < paragraphs.length) {
            _replaceParagraphText(paragraphs[paraIdx], text);
          }
        });
        out.add(ArchiveFile.bytes(
          f.name,
          Uint8List.fromList(
            utf8.encode(xmlDoc.toXmlString()),
          ),
        ));
      }
      return Uint8List.fromList(ZipEncoder().encode(out));
    } catch (e) {
      throw DocumentOpenException(
        'Could not encode the edited presentation: ${e.toString()}',
        e,
      );
    }
  }

  @override
  Future<SaveResult> save(DocumentFile document) async {
    // Deliberately not overwriting the original file.
    throw UnsupportedError(
      'In-place save is disabled to protect the original file. Use Save As.',
    );
  }

  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    final bytes = await exportBytes();
    final base = document.filename
        .replaceAll(RegExp(r'\.pptx$', caseSensitive: false), '');
    final uri = await FilePicker.saveFile(
      fileName: '$base (edited).pptx',
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    );
    if (uri == null) return SaveResult.cancelled;
    return SaveResult.savedAs;
  }

  @override
  void dispose() {
    _doc = null;
    _originalBytes = null;
    _edits.clear();
    _dirty = false;
  }
}

/// Replaces the visible text of one slide paragraph in the slide XML.
///
/// The first text run keeps its run properties (font, size, color); any
/// further text runs in the same paragraph are emptied. Structure, shapes
/// and formatting attributes are untouched.
void _replaceParagraphText(XmlElement paragraph, String newText) {
  final textNodes = paragraph.findAllElements('a:t').toList();
  if (textNodes.isEmpty) return;
  textNodes.first.innerText = newText;
  for (var i = 1; i < textNodes.length; i++) {
    textNodes[i].innerText = '';
  }
}

/// Pure-Dart OOXML slide text extraction (no cloud, no native deps).
class PptxParser {
  static PptxDocument parse(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final slideFiles = archive.files
        .where((f) =>
            !f.isDirectory &&
            RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList()
      ..sort(_bySlideNumber);

    final slides = <PptxSlide>[];
    for (final f in slideFiles) {
      final m =
          RegExp(r'slide(\d+)\.xml$').firstMatch(f.name)!;
      final index = int.parse(m.group(1)!);
      final xmlBytes = f.readBytes();
      if (xmlBytes == null) continue;
      final xml = XmlDocument.parse(utf8.decode(xmlBytes));
      final texts = <String>[];
      // Gather text in document order; join runs within a paragraph.
      // a:t lives inside a:r runs, so the search must be recursive.
      for (final p in xml.findAllElements('a:p')) {
        final buf = StringBuffer();
        for (final t in p.findAllElements('a:t')) {
          buf.write(t.innerText);
        }
        final s = buf.toString().trim();
        if (s.isNotEmpty) texts.add(s);
      }
      slides.add(PptxSlide(index: index, texts: texts));
    }
    return PptxDocument(slides: slides);
  }

  static int _bySlideNumber(ArchiveFile a, ArchiveFile b) {
    final ma = RegExp(r'slide(\d+)\.xml$').firstMatch(a.name)!;
    final mb = RegExp(r'slide(\d+)\.xml$').firstMatch(b.name)!;
    return int.parse(ma.group(1)!).compareTo(int.parse(mb.group(1)!));
  }
}

class _PptxViewer extends StatefulWidget {
  const _PptxViewer({required this.engine});

  final PptxDocumentEngine engine;

  @override
  State<_PptxViewer> createState() => _PptxViewerState();
}

class _PptxViewerState extends State<_PptxViewer> {
  int _current = 0;
  bool _editMode = false;
  final _controllers = <int, TextEditingController>{};

  PptxDocument get doc => widget.engine.document!;

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _clearControllers() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
  }

  void _goSlide(int next) {
    setState(() {
      _current = next;
      _clearControllers();
    });
  }

  void _toggleMode() {
    setState(() {
      _editMode = !_editMode;
      _clearControllers();
    });
  }

  void _applyEdits() {
    final engine = widget.engine;
    final texts = engine.slideTexts(_current);
    var applied = 0;
    _controllers.forEach((i, c) {
      if (i >= 0 && i < texts.length && c.text != texts[i]) {
        if (engine.editSlideText(_current, i, c.text)) applied++;
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(applied > 0
            ? '$applied edit(s) applied. Use Save As to export.'
            : 'No changes to apply.'),
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final slides = doc.slides;
    final slide = slides[_current];
    return Column(
      children: [
        if (widget.engine.capabilities.canEdit)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                onPressed: _toggleMode,
                icon: Icon(_editMode ? Icons.visibility : Icons.edit),
                label: Text(_editMode ? 'View slides' : 'Edit text'),
              ),
            ),
          ),
        Expanded(
          child: _editMode ? _buildEditor() : _buildSlideView(slide),
        ),
        // Slide navigator (kept in both modes).
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _current > 0 ? () => _goSlide(_current - 1) : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('Slide ${slide.index} / ${slides.length}'),
                IconButton(
                  onPressed: _current < slides.length - 1
                      ? () => _goSlide(_current + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSlideView(PptxSlide slide) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                slide.title,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              for (final t in slide.texts.skip(1))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(t)),
                    ],
                  ),
                ),
              if (slide.texts.length <= 1)
                const Text(
                  '(No additional text on this slide)',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEditor() {
    final texts = widget.engine.slideTexts(_current);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text(
            'Text editing — slide structure and layout are kept. '
            'Apply before switching slides.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        Expanded(
          child: texts.isEmpty
              ? const Center(child: Text('No editable text on this slide.'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  itemCount: texts.length,
                  itemBuilder: (context, i) {
                    final isTitle = i == 0;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: TextField(
                        controller: _controllers.putIfAbsent(
                          i,
                          () => TextEditingController(text: texts[i]),
                        ),
                        maxLines: null,
                        decoration: InputDecoration(
                          isDense: true,
                          border: const OutlineInputBorder(),
                          labelText: isTitle ? 'Title' : 'Text ${i + 1}',
                        ),
                      ),
                    );
                  },
                ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: FilledButton(
            onPressed: _applyEdits,
            child: const Text('Apply'),
          ),
        ),
      ],
    );
  }
}
