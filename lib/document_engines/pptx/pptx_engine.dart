import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import '../../core/models/document_file.dart';
import '../document_engine.dart';

/// A single slide's extracted text content.
class PptxSlide {
  const PptxSlide({required this.index, required this.texts});
  final int index; // 1-based
  final List<String> texts;

  String get title => texts.isNotEmpty ? texts.first : 'Slide $index';
}

/// Extracted PPTX content.
class PptxDocument {
  const PptxDocument({required this.slides});
  final List<PptxSlide> slides;
}

/// PPTX engine: offline extraction of slide text from the OOXML package.
///
/// Viewing shows slide text (title + bullets) with a slide navigator.
/// Rendering of full slide visuals (shapes, images, animations) is P3 scope.
class PptxDocumentEngine extends DocumentEngine {
  PptxDocument? _doc;

  @override
  String get name => 'PptxDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: false,
        canSave: false,
        canSaveAs: false,
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
    return _PptxViewer(doc: doc);
  }

  @override
  Future<SaveResult> save(DocumentFile document) async {
    throw UnsupportedError('PPTX editing/saving is not supported in the MVP.');
  }

  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    throw UnsupportedError('PPTX editing/saving is not supported in the MVP.');
  }

  @override
  void dispose() {
    _doc = null;
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
      for (final p in xml.findAllElements('a:p')) {
        final buf = StringBuffer();
        for (final t in p.findElements('a:t')) {
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
  const _PptxViewer({required this.doc});
  final PptxDocument doc;

  @override
  State<_PptxViewer> createState() => _PptxViewerState();
}

class _PptxViewerState extends State<_PptxViewer> {
  int _current = 0;

  @override
  Widget build(BuildContext context) {
    final slides = widget.doc.slides;
    final slide = slides[_current];
    return Column(
      children: [
        Expanded(
          child: Card(
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
          ),
        ),
        // Slide navigator
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  onPressed: _current > 0
                      ? () => setState(() => _current--)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text('Slide ${slide.index} / ${slides.length}'),
                IconButton(
                  onPressed: _current < slides.length - 1
                      ? () => setState(() => _current++)
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
}
