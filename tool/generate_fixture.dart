// Generates a small test DOCX used for on-device manual verification.
// Run with: dart run tool/generate_fixture.dart <output-path>
import 'dart:io';
import 'package:docx_creator/docx_creator.dart';

void main(List<String> args) async {
  final outPath = args.isNotEmpty ? args.first : 'sample.docx';
  final doc = docx()
      .h1('Quarterly Report')
      .p('On-device verification sample for ViewerPal.')
      .p('Second paragraph with more content.')
      .table([
        ['Item', 'Qty'],
        ['Widgets', '12'],
        ['Gadgets', '7'],
      ])
      .build();
  final bytes = await DocxExporter().exportToBytes(doc);
  File(outPath)
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  stdout.writeln('Wrote $outPath (${bytes.length} bytes)');
}
