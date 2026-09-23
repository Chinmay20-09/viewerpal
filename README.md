# Document Environment (viewerpal)

A unified **offline** document environment for Android (Samsung-first): open, view,
modify where supported, save, and share **PDF, DOCX, XLSX and PPTX** files — with
no cloud conversion and no Microsoft 365 dependencies.

## Supported formats

| Format | View | Edit | Save | Share |
|---|---|---|---|---|
| PDF  | ✅ native paging | ❌ (P3) | ❌ | ✅ |
| DOCX | ✅ native rendering + search/zoom | ❌ (next) | ❌ | ✅ |
| XLSX | ✅ sheet tabs + table | ✅ cell values | ✅ Save As | ✅ |
| PPTX | ✅ slide text + navigator | ❌ (P3) | ❌ | ✅ |

Unsupported files are detected and reported safely — the app never crashes on a
bad pick.

## How to run

```bash
flutter pub get
flutter run                 # with an Android device/emulator connected
flutter test                # unit tests
flutter build apk --debug   # build/app/outputs/flutter-apk/app-debug.apk
```

Requirements: Flutter ≥ 3.41 (stable), Android with the current Flutter embedding
(v2). No storage permissions are requested — picking uses Android's system
document picker (SAF).

## Current MVP status

First working pipeline is implemented and analyzed/tested (see
`docs/implementation-status.md` for package decisions, test results, limitations,
and the next task):

```
FILE → DETECT → ROUTE → VIEW → SAVE-AS → SHARE
```

- `lib/core/` — document model + type detection (MIME → extension → header sniff)
- `lib/document_engines/` — pluggable per-format engines behind one interface
- `lib/features/` — home (open + recents) and viewer (save/share actions)

Out of scope (per plan): cloud, accounts, collaboration, AI, macros, real-time
editing, web/desktop.
