import 'dart:typed_data';

import 'package:excel_plus/excel_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../core/models/document_file.dart';
import '../../core/services/document_access.dart';
import '../document_engine.dart';

/// XLSX engine using excel_plus: read, browse sheets, edit a cell, Save As.
class XlsxDocumentEngine extends DocumentEngine {
  Excel? _excel;

  @override
  String get name => 'XlsxDocumentEngine';

  @override
  EngineCapabilities get capabilities => const EngineCapabilities(
        canEdit: true,
        canSave: false, // in-place overwrite deliberately avoided in MVP
        canSaveAs: true,
      );

  Future<void> _ensureLoaded(DocumentFile document) async {
    if (_excel != null) return;
    // Works for both local paths and Android SAF content URIs.
    final bytes = await DocumentAccess.readBytes(document.uri);
    try {
      _excel = Excel.decodeBytes(bytes);
    } on ExcelException catch (e) {
      throw DocumentOpenException(
        'Could not read spreadsheet: ${e.message}',
        e,
      );
    } catch (e) {
      throw DocumentOpenException(
        'Could not read spreadsheet: ${e.toString()}',
        e,
      );
    }
  }

  @override
  Future<void> open(DocumentFile document) => _ensureLoaded(document);

  @override
  Widget buildViewer(BuildContext context, DocumentFile document) {
    return _XlsxViewer(engine: this, document: document);
  }

  List<String> sheetNames() => _excel?.sheets.keys.toList() ?? const [];

  List<List<String>> sheetData(String sheetName, {int maxRows = 200}) {
    final excel = _excel;
    if (excel == null) return const [];
    final sheet = excel.sheets[sheetName];
    if (sheet == null) return const [];
    final rows = <List<String>>[];
    final data = sheet.rows;
    for (final row in data.take(maxRows)) {
      rows.add(row.map(_cellToString).toList());
    }
    return rows;
  }

  static String _cellToString(dynamic cell) {
    final v = cell?.value;
    if (v == null) return '';
    return v.toString();
  }

  /// Edits a single cell (P1 edit capability) on the given sheet.
  bool editCell(String sheetName, int row, int column, String text) {
    final excel = _excel;
    if (excel == null) return false;
    final sheet = excel.sheets[sheetName];
    if (sheet == null) return false;
    // Parse numeric input as numbers so Excel treats it correctly.
    final CellValue? parsed;
    final asInt = int.tryParse(text);
    final asDouble = double.tryParse(text);
    if (asInt != null) {
      parsed = IntCellValue(asInt);
    } else if (asDouble != null) {
      parsed = DoubleCellValue(asDouble);
    } else {
      parsed = TextCellValue(text);
    }
    sheet.updateCell(
      CellIndex.indexByColumnRow(columnIndex: column, rowIndex: row),
      parsed,
    );
    return true;
  }

  @override
  Future<SaveResult> save(DocumentFile document) async {
    // Deliberately not overwriting the original file in the MVP.
    throw UnsupportedError(
      'In-place save is disabled to protect the original file. Use Save As.',
    );
  }

  @override
  Future<SaveResult> saveAs(DocumentFile document) async {
    final excel = _excel;
    if (excel == null) {
      throw StateError('Document not open');
    }
    final raw = excel.save();
    if (raw == null) {
      throw DocumentOpenException('Spreadsheet could not be encoded.');
    }
    final bytes = Uint8List.fromList(raw);
    final base = document.filename.replaceAll(RegExp(r'\.xlsx$'), '');
    final uri = await FilePicker.saveFile(
      fileName: '$base (edited).xlsx',
      bytes: bytes,
      mimeType:
          'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    );
    if (uri == null) return SaveResult.cancelled;
    return SaveResult.savedAs;
  }

  @override
  void dispose() {
    _excel = null;
  }
}

class _XlsxViewer extends StatefulWidget {
  const _XlsxViewer({required this.engine, required this.document});

  final XlsxDocumentEngine engine;
  final DocumentFile document;

  @override
  State<_XlsxViewer> createState() => _XlsxViewerState();
}

class _XlsxViewerState extends State<_XlsxViewer> {
  String _sheet = '';
  bool _editMode = false;
  final _cellEdits = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    final names = widget.engine.sheetNames();
    _sheet = names.isNotEmpty ? names.first : '';
  }

  @override
  void dispose() {
    for (final c in _cellEdits.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_sheet.isEmpty) {
      return const Center(child: Text('This spreadsheet has no sheets.'));
    }
    final rows = widget.engine.sheetData(_sheet);
    return Column(
      children: [
        // Sheet selector
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final name in widget.engine.sheetNames())
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    label: Text(name),
                    selected: name == _sheet,
                    onSelected: (_) => setState(() => _sheet = name),
                  ),
                ),
            ],
          ),
        ),
        // Edit toggle
        if (widget.engine.capabilities.canEdit)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: TextButton.icon(
                onPressed: () => setState(() => _editMode = !_editMode),
                icon: Icon(_editMode ? Icons.lock_open : Icons.lock),
                label: Text(_editMode ? 'Editing on' : 'Edit cells'),
              ),
            ),
          ),
        Expanded(
          child: rows.isEmpty
              ? const Center(child: Text('Empty sheet'))
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        for (var c = 0;
                            c < (rows.isNotEmpty ? rows.first.length : 0);
                            c++)
                          DataColumn(
                            label: Text(_columnLetter(c)),
                          ),
                      ],
                      rows: [
                        for (var r = 0; r < rows.length; r++)
                          DataRow(
                            cells: [
                              for (var c = 0; c < rows[r].length; c++)
                                DataCell(
                                  _editMode
                                      ? TextFormField(
                                          controller: _controllerFor(r, c,
                                              rows[r][c]),
                                          onFieldSubmitted: (v) {
                                            widget.engine.editCell(
                                                _sheet, r, c, v);
                                          },
                                        )
                                      : Text(rows[r][c]),
                                ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  TextEditingController _controllerFor(int r, int c, String initial) {
    final key = '$r:$c';
    return _cellEdits.putIfAbsent(
      key,
      () => TextEditingController(text: initial),
    );
  }

  static String _columnLetter(int index) {
    var i = index;
    final b = StringBuffer();
    while (i >= 0) {
      b.writeCharCode(65 + (i % 26));
      i = (i ~/ 26) - 1;
    }
    return b.toString();
  }
}

