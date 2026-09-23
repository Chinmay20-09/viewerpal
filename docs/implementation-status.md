# Document Environment — Implementation Status

Last updated: 2026-09-21 (DOCX edit + Save As pipeline enabled)

## What this is

The first working document pipeline for the offline Document Environment Android app:

```
FILE → DETECT → ROUTE → VIEW → SAVE-AS → SHARE
```

## Packages selected

| Purpose | Package | Version | Why |
|---|---|---|---|
| File picking (SAF) | `file_picker` | 13.1.0 | Uses Android system document picker (SAF); no broad storage permissions; new non-deprecated API (`FilePicker.pickFiles`, `FilePicker.saveFile`). |
| PDF | `flutter_pdfview` | 1.4.5 | 750 likes, actively published (49 days ago), native AndroidPdfViewer rendering, offline, local file paths. Best-maintained PDF viewer option. |
| DOCX | `docx_file_viewer` | 1.0.4 | Pure-Flutter native rendering (no WebView/PDF conversion), search + zoom, published 8 days ago, same author ecosystem as `docx_creator`. |
| DOCX model (parse/edit/export) | `docx_creator` | 1.3.3 | Active (8 days), `DocxReader` loads existing DOCX to an AST, `DocxExporter.exportToBytes` writes it back. Now used for DOCX text editing and Save As (APIs verified from installed 1.3.3 source, not docs). |
| XLSX | `excel_plus` | 2.22.0 | Actively maintained (3 days ago), read/edit/save .xlsx, typed `ExcelException`, verified API from source before use. |
| PPTX | `archive` 4.3.0 + `xml` 7.0.1 | — | No viable maintained offline PPTX viewer exists, so the PPTX engine extracts slide text directly from the OOXML zip. Fully offline, tiny, stable packages. |
| Share | `share_plus` | 13.3.0 | Standard Android share-sheet plugin; current `SharePlus.instance.share(ShareParams(files: [XFile]))` API. |
| Recents | `shared_preferences` | 2.5.5 | Lightweight JSON list persistence; deliberately no database. |
| Save As target | `file_picker.saveFile` | — | SAF-backed save dialog; no storage permissions. |

## Packages rejected

| Candidate | Reason |
|---|---|
| `microsoft_viewer` | Unverified publisher, 13 likes / 238 downloads, last published 8 months, heavy dependency chain (`flutter_widget_from_html`, `flutter_isolate`), "very basic" viewer. Poor maintenance signal for a core engine. |
| `excel` (original) | Superseded by `excel_plus`, which is a maintained drop-in with better performance and active releases. |
| `excel_plus` doc candidate `docx_viewer_plus` | Could not verify existence/maintenance on pub.dev; chose `docx_file_viewer` + `docx_creator` instead. |
| `dart_pdf_editor` | Could not verify as maintained/viable on pub.dev; PDF *editing* is P3 scope anyway, so a proven viewer was chosen. |
| `pdfrx` | Strong alternative, but `flutter_pdfview` is the more widely adopted Android-focused viewer; revisit if PDF needs fail on device. |
| Apryse/Syncfusion/PSPDFKit SDKs | Commercial/licensing heavy and against the minimal-dependency MVP constraint. |

## Supported operations

- Open via Android system picker (pdf/docx/xlsx/pptx filter)
- Type detection: MIME first, extension fallback, PDF header sniff as last resort
- Routing to per-format engine through a common `DocumentEngine` interface with explicit capability flags
- PDF: native paging viewer with page indicator; header validation before render
- DOCX: native rendering, search, zoom, paged mode; ZIP-magic validation; **text editing** (paragraph text replacement over the parsed AST); **live preview** of edits (rendered from in-memory AST bytes — no file writes — via the View/Edit toggle); **Save As** (SAF dialog, `<name> (edited).docx`)
- XLSX: sheet tabs, cell table, cell-value editing, Save As (SAF dialog), numeric parsing
- PPTX: offline slide text extraction (paragraph order preserved), slide navigator
- Share any open document via Android share sheet
- Recents list (max 10) with reopen and stale-entry pruning
- Safe errors: unsupported type, corrupt file, missing file, picker cancel, save failure, viewer render failure — surfaced as UI messages, no crashes

## Unsupported operations (deliberate)

- PDF edit/save (P3)
- DOCX in-place save (originals are never overwritten; Save As only), tracked changes, comments, headers/footers editing, table/complex layout editing
- PPTX visual slide rendering (shapes/images/animations — P3)
- In-place overwrite save for any format (protects originals; Save As for XLSX and DOCX)
- Legacy `.doc/.xls/.ppt` binary formats
- Cloud, accounts, collaboration, AI, macros, real-time editing, web/desktop

## Test results (2026-09-21, DOCX editing + live preview milestone)

- `flutter analyze` → No issues found
- `flutter test` → 30/30 passed (17 previous + 13 new DOCX tests)
  - Type detection: MIME ×4, extension fallback ×2, unknown ×1, header sniff ×1, JSON round-trip ×1, fromPickedFile ×1
  - Routing: PDF/DOCX/XLSX/PPTX ×4, unknown throws ×1, factory injection (mocks) ×1, routeAndOpen ×1
  - DOCX: parse (heading/paragraphs/table) ×2, invalid/empty-file rejection ×2, text-run edit ×1, paragraph edit ×1, index bounds ×1, export bytes ×1, ZIP validity ×1, full round-trip (parse→edit→export→re-parse→verify) ×1, re-parse readability ×1
- `flutter build apk --debug` → Built `build/app/outputs/flutter-apk/app-debug.apk`
- DOCX round-trip verdict: **PASS** — export is a valid ZIP, edited text persists, heading/paragraphs/tables remain readable, and the exported file re-opens in the app. `DocxDocumentEngine.capabilities` therefore exposes `canEdit = true`, `canSaveAs = true` (in-place `canSave` stays false).

## Known limitations

1. DOCX editing is text-level only: editing a paragraph replaces its text content (first run's formatting is kept, extra text runs in that paragraph are dropped). Tables, images, headers/footers, tracked changes and comments are not editable. Documents with features the reader maps to raw XML may lose those parts on export (known docx_creator reader limitation). The live preview is rendered from that same AST export, so it may differ slightly from the original-file rendering and only reflects edits after Apply.
2. PDF is view-only; engines advertise this via `capabilities` so the UI hides save buttons.
3. XLSX viewer caps rendering at 200 rows per sheet for responsiveness.
4. PPTX shows text content only; no shapes/images/layout.
5. Recents rely on the path returned by the picker; files moved/deleted after picking are pruned on next tap with a friendly error.
6. On-device verification: **performed** on a physical device (CPH2603, Android 16) during this session. Verified: APK install, app launch, DOCX open from recents, native view, text edit applied via the editor (including typing into a paragraph with no text runs — insertion path), Save As through the SAF dialog (default filename `<name> (edited).docx` shown and accepted), exported file written to `/sdcard/Download`, app closed, exported DOCX reopened through the app's picker, and the edited text visible in the reopened document. Exported file also pulled to the host and re-verified (valid ZIP, 127 paragraphs + 2 tables parse, edit persisted, original content intact). The **live preview** was verified on device: after Apply + View/Edit toggle, the rendered page showed the typed marker text (`PREVIEWOK`) without any Save operation. (Session was interrupted twice by an incoming call and screen lock; the flow was resumed and completed.)

## Next implementation task

Physical-device verification of the DOCX edit + Save As flow (open → view → edit → Save As → reopen exported file → share), then continue the capability matrix (PDF/PPTX improvements or DOCX table-cell editing) per product priorities.
