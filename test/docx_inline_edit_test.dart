import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:viewerpal/core/models/document_file.dart';
import 'package:viewerpal/core/services/document_access.dart';
import 'package:viewerpal/core/services/file_service.dart';
import 'package:viewerpal/document_engines/document_engine.dart';
import 'package:viewerpal/document_engines/docx/docx_engine.dart';
import 'package:viewerpal/features/viewer/viewer_screen.dart';

import 'docx_roundtrip_test.dart' show buildFixtureDocx;

/// Records the platform FilePicker calls so tests can stub SAF behavior.
class _RecordingPicker extends FilePickerPlatform {
  final List<String> calls = [];
  List<PlatformFile> pickResult = [];
  Uri? saveResult;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add('pickFiles');
    return pickResult;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    calls.add('saveFile:$fileName');
    return saveResult;
  }
}

/// Minimal PlatformFile standing in for an Android SAF pick result.
final class _FakePickedFile extends PlatformFile {
  _FakePickedFile(this._name, this._uri);

  final String _name;
  final Uri _uri;

  @override
  String get name => _name;

  @override
  Uri get uri => _uri;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late File fixtureFile;
  late Uint8List fixtureBytes;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('docx_inline_edit');
    fixtureBytes = await buildFixtureDocx();
    fixtureFile = File('${tempDir.path}/testing.docx')
      ..writeAsBytesSync(fixtureBytes);
  });

  tearDownAll(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  DocumentFile makeDoc(String path, {String name = 'testing.docx'}) =>
      DocumentFile(
          uri: path, filename: name, extension: 'docx', type: DocumentType.docx);

  group('1–2. Same-screen edit mode + model binding', () {
    testWidgets(
        'Edit enters edit mode on the SAME screen; typing updates the model',
        (tester) async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      // Drive the engine directly, as the real ViewerScreen host does: the
      // SAME screen hosts both modes via the engine's editMode notifier.
      // (Edit mode is flipped through the SAME notifier the app bar uses;
      // no second route is pushed at any point.)
      engine.editMode.value = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('testing.docx'),
              actions: [
                ValueListenableBuilder<bool>(
                  valueListenable: engine.editMode,
                  builder: (context, editing, _) => IconButton(
                    icon: Icon(editing ? Icons.save : Icons.edit),
                    onPressed: () => engine.editMode.value = !editing,
                  ),
                ),
              ],
            ),
            body: engine.buildViewer(tester.element(find.byType(Scaffold)),
                makeDoc(fixtureFile.path)),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('testing.docx'), findsOneWidget,
          reason: 'AppBar title must remain; no new screen was pushed');
      expect(find.byIcon(Icons.save), findsOneWidget,
          reason: 'app bar shows Save while editing');
      expect(find.byType(TextField), findsWidgets,
          reason: 'edit mode renders the document text as editable fields');

      // Edit an existing paragraph through an editable field. The engine
      // model must update immediately (no Apply step).
      final target = engine
          .paragraphs()
          .firstWhere((p) => p.text.contains('Second paragraph'));
      final field =
          find.widgetWithText(TextField, 'Second paragraph with more content.');
      expect(field, findsOneWidget);
      await tester.enterText(field, 'Typed on the same screen.');
      await tester.pump();

      expect(engine.isDirty, isTrue);
      expect(
        engine.paragraphs().firstWhere((p) => p.index == target.index).text,
        'Typed on the same screen.',
      );

      // No "Paragraph 1" style labels and no Apply button anywhere.
      expect(find.text('Paragraph 1'), findsNothing);
      expect(find.text('Apply'), findsNothing);
      expect(find.text('View document'), findsNothing);
    });
  });

  group('3–6. Save As round-trip + original untouched', () {
    test('Save As exports modified content and can be reopened', () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));

      final dest = File('${tempDir.path}/testing (edited).docx');
      final savedUris = <Uri>[];
      engine.setSaveAsHandler((bytes, suggestedName, mimeType) async {
        expect(suggestedName, 'testing (edited).docx');
        dest.writeAsBytesSync(bytes);
        savedUris.add(Uri.file(dest.path));
        return Uri.file(dest.path);
      });

      final originalBytes = fixtureFile.readAsBytesSync();

      final target = engine
          .paragraphs()
          .firstWhere((p) => p.text.contains('Second paragraph'));
      expect(
          engine.editParagraphText(
              target.index, 'Round trip survived inline editing.'),
          isTrue);

      final result = await engine.saveAs(makeDoc(fixtureFile.path));
      expect(result, SaveResult.savedAs);
      expect(engine.isDirty, isFalse, reason: 'dirty flag resets after save');
      expect(engine.lastSavedName, 'testing (edited).docx');
      expect(engine.lastSavedUri, Uri.file(dest.path).toString());
      expect(savedUris, hasLength(1));

      // Original document must NOT be overwritten.
      final after = fixtureFile.readAsBytesSync();
      expect(after.length, originalBytes.length);
      expect(String.fromCharCodes(after),
          String.fromCharCodes(originalBytes),
          reason: 'original DOCX bytes must be identical after Save As');

      // 4–5. Reopen the exported file with a fresh engine; the edited text
      // must survive the round trip and other content must remain.
      final engine2 = DocxDocumentEngine();
      await engine2.open(makeDoc(dest.path, name: 'testing (edited).docx'));
      final texts = engine2.paragraphs().map((p) => p.text).toList();
      expect(
          texts.any((t) => t.contains('Round trip survived inline editing.')),
          isTrue);
      expect(texts.any((t) => t.contains('Quarterly Report')), isTrue);
      engine2.dispose();
    });

    test('cancelling Save As leaves the document untouched and dirty',
        () async {
      final engine = DocxDocumentEngine();
      await engine.open(makeDoc(fixtureFile.path));
      engine.setSaveAsHandler((bytes, suggestedName, mimeType) async {
        return null; // user cancelled the SAF dialog
      });

      final target = engine
          .paragraphs()
          .firstWhere((p) => p.text.contains('Second paragraph'));
      engine.editParagraphText(target.index, 'Unsaved edit');

      final result = await engine.saveAs(makeDoc(fixtureFile.path));
      expect(result, SaveResult.cancelled);
      expect(engine.isDirty, isTrue);
      expect(engine.lastSavedName, isEmpty);
      expect(File('${tempDir.path}/testing (edited).docx').existsSync(),
          isFalse, reason: 'cancelled save must not write the destination');
      engine.dispose();
    });
  });

  group('7. Invalid / stale URI handling', () {
    test('engine open on a stale path throws DocumentOpenException', () async {
      final engine = DocxDocumentEngine();
      await expectLater(
        engine.open(makeDoc('${tempDir.path}/deleted_file.docx')),
        throwsA(isA<DocumentOpenException>()),
      );
      engine.dispose();
    });

    test('DocumentAccess reports content URIs as inaccessible, not crash',
        () async {
      // No platform channel handler is registered in the test environment,
      // so a content:// URI read fails as MissingPluginException, surfaced
      // as DocumentAccessException — the "File is no longer accessible"
      // path used by HomeScreen.
      expect(
        await DocumentAccess.isAccessible(
            'content://com.android.providers.downloads.documents/document/9999'),
        isFalse,
      );
      expect(
        () => DocumentAccess.readBytes(
            'content://com.android.providers.downloads.documents/document/9999'),
        throwsA(isA<DocumentAccessException>()),
      );
    });

    test('DocumentFile keeps the SAF source URI for reopening', () {
      const doc = DocumentFile(
        uri: 'content://com.android.providers.downloads.documents/document/42',
        filename: 'testing.docx',
        extension: 'docx',
        type: DocumentType.docx,
        sourcePath:
            'content://com.android.providers.downloads.documents/document/42',
      );
      final json = doc.toJson();
      final restored = DocumentFile.fromJson(json);
      expect(restored.sourcePath, doc.sourcePath);
      expect(restored.originalUri, doc.sourcePath,
          reason: 'the persisted SAF URI must survive serialization');
    });

    testWidgets(
        'ViewerScreen shows a friendly error for an inaccessible document',
        (tester) async {
      final stale = DocumentFile(
          uri: '${Directory.systemTemp.path}/definitely_missing_9281.docx',
          filename: 'gone.docx',
          extension: 'docx',
          type: DocumentType.docx);
      await tester.pumpWidget(
        MaterialApp(home: ViewerScreen(document: stale)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('no longer accessible'), findsOneWidget);
    });
  });

  group('Picker identity (SAF URI preservation)', () {
    test('FileService stores the content URI, not the cache path',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final recorder = _RecordingPicker();
      FilePickerPlatform.instance = recorder;

      const contentUri =
          'content://com.android.providers.downloads.documents/document/42';
      recorder.pickResult = [_FakePickedFile('testing.docx', Uri.parse(contentUri))];

      final service = FileService();
      final doc = await service.pickDocument();

      expect(doc.uri, contentUri,
          reason: 'document identity must be the SAF content URI');
      expect(doc.sourcePath, contentUri);
      expect(doc.uri.contains('file_picker'), isFalse,
          reason: 'the ephemeral cache path must never be persisted');
      expect(doc.type, DocumentType.docx);

      final recents = await service.loadRecents();
      expect(recents.first.uri, contentUri);
    });
  });
}
