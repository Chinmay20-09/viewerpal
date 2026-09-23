# Review — 48-Hour MVP: First Working Document Pipeline

**Date:** 2026-09-21
**Goal:** FILE → DETECT → ROUTE → VIEW → SAVE-AS → SHARE, fully offline on Android.

---

## Files changed / created

```
lib/
├── main.dart                              (replaced counter app)
├── app/
│   └── app.dart                           MaterialApp + routes
├── core/
│   ├── models/
│   │   └── document_file.dart             DocumentFile + DocumentType + detection
│   └── services/
│       ├── document_router.dart           type → engine routing (testable factories)
│       └── file_service.dart              SAF picking + recents persistence
├── features/
│   ├── home/
│   │   └── home_screen.dart               Open Document + Recent documents
│   └── viewer/
│       └── viewer_screen.dart             engine hosting + Save/Save As/Share + errors
└── document_engines/
    ├── document_engine.dart               abstract interface + capabilities
    ├── pdf/pdf_engine.dart                flutter_pdfview viewer + header validation
    ├── docx/docx_engine.dart              docx_file_viewer + ZIP validation
    ├── xlsx/xlsx_engine.dart              excel_plus: view, edit cell, Save As
    └── pptx/pptx_engine.dart              offline OOXML text extraction + navigator

test/
├── document_file_test.dart                10 tests (detection)
└── document_router_test.dart              7 tests (routing + mocks)

docs/
└── implementation-status.md               package decisions, tests, limitations

README.md                                  project purpose, formats, how to run
pubspec.yaml                               dependencies (see below)
```

Deleted: default counter `lib/main.dart` UI, `test/widget_test.dart` (replaced).

## Dependencies added (all verified against pub.dev before install)

| Package | Version | Role |
|---|---|---|
| file_picker | 13.1.0 | SAF system picker (open + save dialog), no storage permissions |
| flutter_pdfview | 1.4.5 | native PDF rendering |
| docx_file_viewer | 1.0.4 | native Flutter DOCX rendering (search/zoom/paged) |
| docx_creator | 1.3.3 | DOCX parse model for the future edit/save step |
| excel_plus | 2.22.0 | XLSX read/edit/encode |
| archive + xml | 4.3.0 / 7.0.1 | PPTX slide text extraction (no PPTX package exists that passed review) |
| share_plus | 13.3.0 | Android share sheet |
| shared_preferences | 2.5.5 | recents storage |
| path_provider | 2.1.6 | (installed for future save locations) |

**Rejected:** `microsoft_viewer` (unverified publisher, stale, heavy deps), `excel`
(superseded by excel_plus), `dart_pdf_editor` / `docx_viewer_plus` (could not be
verified as maintained), commercial SDKs (licensing/scope).

## Functionality implemented

1. **Open** — "Open Document" button → Android system document picker filtered to pdf/docx/xlsx/pptx.
2. **Detect** — MIME type first; extension fallback; PDF header sniff last resort. `UNKNOWN` is a first-class result.
3. **Route** — `DocumentRouter` returns the engine for the detected type via injectable factories; unknown types throw cleanly.
4. **View** — per-format engines behind one `DocumentEngine` interface with explicit `EngineCapabilities` (the abstraction does not pretend formats are identical):
   - PDF: native paging + page indicator
   - DOCX: paged native rendering with search/zoom
   - XLSX: sheet tabs + cell table + cell editing
   - PPTX: slide text cards + prev/next navigator
5. **Save** — XLSX only: Save As through the SAF dialog (`… (edited).xlsx`), original file preserved; other engines throw `UnsupportedError` which the UI converts to a clear message. No destructive overwrite.
6. **Share** — share sheet for every open document.
7. **Recents** — last 10 documents, JSON in SharedPreferences, reopen on tap, stale entries pruned with a friendly error.
8. **Error handling** — picker cancel, unreadable/missing file, unsupported type, corrupt files (per-engine validation), save failure, viewer render failure: all surfaced as UI messages; no unhandled exceptions in the open flow.

## Tests run / results

| Command | Result |
|---|---|
| `flutter analyze` | ✅ No issues found |
| `flutter test` | ✅ 17/17 passed (10 detection + 7 routing incl. mock engines & unknown-format handling) |
| `flutter build apk --debug` | ✅ Built `build/app/outputs/flutter-apk/app-debug.apk` (184.9 s) |

## On-device status — IMPORTANT

`adb devices` shows **no device connected** in this session, so steps "install APK
on the phone" and manual checks 1–9 (launch, pick each format, correct handler,
safe unsupported handling, share) **have NOT been executed and are NOT claimed as
passing**. To verify on your phone:

```bash
adb install build/app/outputs/flutter-apk/app-debug.apk
# or
flutter run
```

Then check: opens → Open Document → pick a PDF/DOCX/XLSX/PPTX → correct viewer →
share icon → open an unsupported file (e.g. `.zip`) → friendly error.

## Known limitations

- PDF & DOCX & PPTX are view-only (P3); buttons hidden via capability flags, not fake-enabled.
- DOCX save is deliberately disabled until `docx_creator` round-trip fidelity is validated — avoids destroying user files.
- PPTX shows text only; no shapes/images/animations.
- XLSX table renders first 200 rows per sheet.
- In-place Save is intentionally not offered for any format in the MVP.
- Legacy `.doc/.xls/.ppt` not supported (only OOXML + PDF).

## Exact next task

**DOCX edit + Save As pipeline:** load with `DocxReader`, apply text edits to the
AST, export via `DocxExporter.exportToBytes`, run a round-trip fidelity check on a
sample corpus, then flip `DocxDocumentEngine.capabilities` to `canEdit/canSaveAs`.
