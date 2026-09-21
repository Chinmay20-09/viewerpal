# Document Engines

## 1. Objective

Select offline-capable document libraries that can be integrated into the Flutter Android application within the 48-hour MVP deadline.

The priority is:

1. Android compatibility
2. Offline operation
3. Ability to open existing files
4. Ability to save modifications
5. Flutter integration
6. Open-source / permissive licensing
7. Minimum implementation time

Full Microsoft Office compatibility is not required for the MVP.

---

# 2. Selected Strategy

The application will use separate document engines behind a common application interface.

```text
                    Document Environment
                            │
                     Document Router
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
      PDF                 Office              Office
        │                   │                   │
  PDF Engine          DOCX Engine       XLSX/PPTX Engines
```

The application must not depend on Microsoft 365 or an online conversion service.

---

# 3. PDF

## Candidate

`dart_pdf_editor`

The package provides both PDF viewing and editing functionality, including text selection, search, annotations, free text, images, forms, signatures, and saving. It runs directly in Dart and supports Android. It is Apache-2.0 licensed.

### MVP Usage

```text
Open PDF
   ↓
Render
   ↓
Select / Search
   ↓
Add text or annotation
   ↓
Save
   ↓
Share
```

### Decision

**Use `dart_pdf_editor` as the primary PDF engine.**

If integration problems occur during the first implementation window, use a simpler Android PDF annotation package as fallback. `flutter_pdf_annotations`, for example, supports Android, annotation, image stamping, undo, saving, and sharing under MIT licensing.

---

# 4. DOCX

## Candidate

`docx_viewer_plus`

The package supports DOCX viewing and editing and provides rich-text editing capabilities including formatting, headings, lists, colors, links, tables, images, and other document elements. It supports Android.

Another option is `docx_viewer`, which focuses primarily on extracting and displaying DOCX content and is therefore more appropriate as a viewer fallback than as the main editing engine.

### MVP Usage

```text
Open DOCX
   ↓
Render document
   ↓
Basic text editing
   ↓
Formatting
   ↓
Save DOCX
   ↓
Share
```

### Decision

**Use `docx_viewer_plus` for DOCX if its current Android integration works in the project.**

If it fails to integrate reliably, downgrade the DOCX requirement to high-quality viewing plus a controlled/basic editing implementation rather than spending the MVP deadline fighting the library.

---

# 5. XLSX

## Primary Candidate

`excel_plus`

`excel_plus` is a Dart/Flutter library capable of reading, creating, editing, and styling XLSX files. It also supports formulas, charts, and CSV and works on mobile.

This is useful because the MVP specifically requires cell editing rather than simply rendering a spreadsheet.

### MVP UI

The application will provide its own spreadsheet editing surface around the workbook data.

```text
┌────┬────┬────┬────┐
│ A  │ B  │ C  │ D  │
├────┼────┼────┼────┤
│ 10 │ 20 │ 30 │ 40 │
├────┼────┼────┼────┤
│ 15 │ 25 │ 35 │ 45 │
└────┴────┴────┴────┘
        ↓
     Edit Cell
        ↓
     Save XLSX
```

### Alternative

`worksheet` provides a high-performance spreadsheet UI with cell selection and editing and Android support.

### Decision

**Use `excel_plus` as the XLSX file engine.**

Build only the spreadsheet UI required for the MVP.

---

# 6. PPTX

PPTX is the highest-risk format for editing within 48 hours.

Existing Flutter packages provide PPTX generation, but generation is not equivalent to editing arbitrary existing PowerPoint files. `dart_pptx` / `flutter_pptx` primarily focus on creating presentations.

A generic `microsoft_viewer` package can view DOCX, XLSX, and PPTX files, including text, images, tables, and basic formatting. However, it is explicitly described as a basic viewer rather than a full editor.

### MVP Strategy

Prioritize:

```text
PPTX
 ↓
Open
 ↓
View
 ↓
Basic text/image modification if feasible
 ↓
Save
```

Do not attempt complete PowerPoint compatibility.

### Decision

**Use the available Office viewer for PPTX viewing and implement only the minimum modification path that can be proven reliable.**

If arbitrary PPTX editing cannot be completed reliably within the deadline, the documented fallback is:

```text
PPTX → View → Export/Save unchanged → Share
```

rather than blocking the entire application.

---

# 7. Common Viewer Alternative

`microsoft_viewer` can provide a single viewer for DOCX, XLSX, and PPTX. It supports Android and is MIT licensed. It handles basic text, images, tables, and formatting.

It is useful as a rapid viewer solution but should **not** become the application's architecture.

The application should retain separate format-specific services so that editing capabilities can be added independently.

---

# 8. Architecture Decision

The application will use an abstraction layer.

```text
DocumentService
│
├── PdfDocumentService
├── DocxDocumentService
├── XlsxDocumentService
└── PptxDocumentService
```

Each service is responsible for:

```text
open()
view()
edit()
save()
share()
```

Not every format must implement every operation identically.

For example:

```text
PDF
open ✓
view ✓
edit ✓
save ✓

DOCX
open ✓
view ✓
edit ✓
save ✓

XLSX
open ✓
view ✓
edit ✓
save ✓

PPTX
open ✓
view ✓
edit limited
save limited
```

---

# 9. Licensing

Before final APK distribution, verify the exact package version and license included in the dependency tree.

Preferred licenses for the MVP include:

- MIT
- Apache-2.0
- BSD

Commercial SDKs should not be introduced unless explicitly approved.

---

# 10. Offline Requirement

No document operation should require a server.

```text
File
 ↓
Local Android Storage
 ↓
Flutter Application
 ↓
Document Engine
 ↓
Modified File
 ↓
Local Storage
```

No cloud conversion service should be used.

---

# 11. 48-Hour Selection Rule

A library is considered acceptable only if:

1. It builds successfully on Android.
2. It works without internet.
3. It can process a real sample document.
4. It can return/save the resulting file.
5. It does not introduce unacceptable licensing restrictions.
6. Integration can be completed within the MVP deadline.

A technically superior library that cannot be integrated quickly is not useful for this MVP.

---

# 12. Final Engine Plan

| Format | Engine Strategy | MVP |
|---|---|---|
| PDF | `dart_pdf_editor` | View + edit + save |
| DOCX | `docx_viewer_plus` | View + basic edit + save |
| XLSX | `excel_plus` + Flutter UI | View + cell edit + save |
| PPTX | Office viewer + limited editing | View + limited edit/save |

The exact dependency versions must be pinned after the first successful Android build.

---

# 13. Fallback Philosophy

The project must never be blocked by one document format.

If an editing engine fails:

```text
Full Editing
     ↓
Basic Editing
     ↓
View + Save
     ↓
View Only
```

The team should move down this ladder rather than spending several hours attempting to reproduce Microsoft Office functionality.

---

# 14. Current Recommendation

Proceed immediately with implementation.

Do not spend additional development time comparing dozens of libraries.

The next task is to create the Flutter application and prove:

```text
APK
 ↓
Open File
 ↓
Detect Format
 ↓
PDF/DOCX/XLSX/PPTX Handler
 ↓
View
```

Once that pipeline works, editing can be added format-by-format.