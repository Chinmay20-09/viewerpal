import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/document_engines/docx/docx_engine.dart';

import 'docx_roundtrip_test.dart' show buildFixtureDocx;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late File fixtureFile;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('docx_scratch');
    fixtureFile = File('${tempDir.path}/t.docx')
      ..writeAsBytesSync(await buildFixtureDocx());
  });

  testWidgets('scratch A: plain pump', (tester) async {
    debugPrint('A-START');
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('x'))));
    debugPrint('A-END');
    expect(find.text('x'), findsOneWidget);
  });

  testWidgets('scratch B: engine open only', (tester) async {
    debugPrint('B-START');
    final engine = DocxDocumentEngine();
    final doc = DocumentFile(
        uri: fixtureFile.path,
        filename: 't.docx',
        extension: 'docx',
        type: DocumentType.docx);
    await engine.open(doc);
    debugPrint('B-OPENED');
    engine.dispose();
    debugPrint('B-END');
  });
}
