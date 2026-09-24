# ViewerPal — Audit

Date: 2026-09-24 · Branch: `main`

## ✅ Stuff done

### Bug fix (this session)
- **`lib/document_engines/pptx/pptx_engine.dart`** — fixed both analyzer errors:
  - `File` was undefined (no `dart:io` import) → replaced direct file access with
    `DocumentAccess.readBytes()`, matching the DOCX engine convention. This also makes the
    PPTX engine work with Android SAF `content://` URIs, not just local paths.
  - Removed the broken `import '/../core/services/document_access.dart'` (unused, malformed path).

### Verification
- `flutter analyze` → **No issues found** (0 errors, 0 warnings).
- `test/pptx_edit_test.dart` → **14/14 passed** (parsing, editing, export round-trip, viewer widget, XML sanity).
- `test/document_file_test.dart` → **10/10 passed** (type detection, MIME/extension/header sniffing, JSON round-trip).
- `test/document_router_test.dart` → **7/7 passed** (PDF/DOCX/XLSX/PPTX routing, custom factories, routeAndOpen).

### Existing feature state
- DOCX engine: parse → inline edit → Save As (`<name> (edited).docx`); original never overwritten.
- XLSX engine: text-level editing with Save As; in-place save deliberately disabled.
- PPTX engine: slide text extraction, per-paragraph editing, Save As; layout/images/theme preserved byte-for-byte.
- PDF engine: viewing only (view-only MVP, no edit/save capabilities).
- `DocumentAccess`: local paths + SAF content URIs, read-only local mirrors, app-managed saved copies.
- Android side: `MainActivity.kt` method channel (`viewerpal/document_access`) for SAF reads, temp/app dirs.

## ⬜ Stuff remaining

### Testing
- [ ] **Full `flutter test` run hangs** — `test/scratch_isolate_test.dart` is a debugging scratch file
  (engine-open smoke test) that never completes in the suite. Delete it or fix/timeout it, then re-run the whole suite.
- [ ] Not yet verified individually (kept timing out in group runs): `docx_inline_edit_test.dart`,
  `docx_roundtrip_test.dart`, `pdf_edit_test.dart`. Run each alone to confirm.
- [ ] **On-device (phone) verification not done** — USB debugging was connected (CPH2603, Android 16),
  but `flutter run` on the device + manual open/edit/Save As of real PDF/DOCX/XLSX/PPTX files was not executed.
- [ ] No integration test for SAF content-URI flow (revoked permission, stale recents).

### Engine gaps (by design / deferred)
- [ ] **PDF**: no editing, annotation, or Save As (view-only MVP).
- [ ] **PPTX**: full slide visual rendering (shapes, images, animations) is P3 scope; currently text-only view.
- [ ] All editable engines: **in-place save intentionally disabled** — decide if/when to support it.
- [ ] DOCX: tables not editable (top-level paragraphs only).
- [ ] Save As goes through `FilePicker.saveFile`; DOCX engine still has the default `UnimplementedError`
  save-as handler unless a real handler is installed — confirm the viewer screen wires one in.

### Housekeeping
- [ ] Remove `test/scratch_isolate_test.dart` (debug scratch) from the repo.
- [ ] `pubspec.yaml` still has placeholder description "A new Flutter project."
- [ ] Repository visibility is unknown; no CI configured (add analyze + test workflow once suite un-hangs).
