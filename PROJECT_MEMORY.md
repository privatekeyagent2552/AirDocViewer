# Air Docs Viewer — Complete Project Memory

> **Purpose:** Single source of truth for Cursor / AI agents when switching accounts or onboarding fresh context.  
> **Read this first** before making changes. Also see [README.md](README.md), [AGENTS.md](AGENTS.md), [BUILD_GUIDE.md](BUILD_GUIDE.md).

**Last updated:** August 2026  
**Developer:** Dte of Crypto Sys Dev / Crypto Sys Development  
**Private GitHub:** https://github.com/privatekeyagent2552/AirDocViewer  
**Workspace path:** `C:\Users\hashi\AndroidStudioProjects\AirDocsViewer`

---

## 1. What This App Is

**Air Docs Viewer** (launcher label: **AirDoc Viewer**) is an **offline-first Android document viewer** built with **Flutter**. It opens 40+ file formats without cloud services, ads, or analytics.

- Users import files into **private app-scoped storage**
- App can also open files from **other apps** (Files, Gmail, etc.) via Android intent filters — a **universal document opener**
- No LibreOffice, no embedded office suite — lightweight ~75–80 MB release APK
- Strict privacy: release build removes `INTERNET` permission; hyperlinks copy to clipboard instead of opening browser

---

## 2. Identity & Naming (Important — Mixed Names)

| Item | Value |
|------|--------|
| **Launcher / home screen label** | `AirDoc Viewer` (set in `android/app/build.gradle.kts` → `manifestPlaceholders["appName"]`) |
| **In-app branding strings** | Mix of `AirDoc Viewer` and `Air Docs Viewer` in `lib/l10n/app_*.arb` |
| **Flutter package** | `air_docs_viewer` |
| **Android applicationId** | `com.airdocsviewer` (never change without Play Store impact) |
| **Version name** | `1.0.0` |
| **Version code** | `6` (in `android/app/build.gradle.kts`) |
| **pubspec version** | `1.0.0+1` |
| **Min SDK** | 26 (Android 8.0+) |
| **Target ABI** | `arm64-v8a` only |
| **APK names** | `AirDocsViewer-release.apk` / `AirDocsViewer-debug.apk` |

**Legacy names to ignore:** Fadocx, LibreOfficeKit, old hacker icon — all removed.

---

## 3. Release Signing & Keystore (LOCAL — DO NOT COMMIT)

**Never commit** these files (already in `.gitignore`):

| File | Purpose |
|------|---------|
| `android/upload-keystore.jks` | Release keystore |
| `android/key.properties` | Gradle signing config |
| `android/keystore-credentials.txt` | Local password notes |

| Field | Value |
|-------|--------|
| Package | `com.airdocsviewer` |
| Keystore path | `android/upload-keystore.jks` |
| Key alias | `airdocsviewer` |
| Passwords | See local `android/keystore-credentials.txt` only |

**`android/key.properties` template:**
```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=airdocsviewer
storeFile=upload-keystore.jks
```

**Android Studio:** Build → Generate Signed App Bundle or APK → choose `android/upload-keystore.jks` → alias `airdocsviewer`.

If `key.properties` is missing, release builds fall back to the **debug keystore** (local testing only — do not ship).

### Shipping APK name & paths

| Item | Value |
|------|--------|
| Release filename | **`AirDocsViewer-release.apk`** |
| Preferred path | `android/app/release/AirDocsViewer-release.apk` |
| Flutter CLI path | `build/app/outputs/flutter-apk/app-release.apk` |
| Naming config | `android/app/build.gradle.kts` → `archivesName` / `outputFileName` |

```bash
dart run pdfrx:remove_wasm_modules
flutter build apk --release
# then use / copy to:
# android/app/release/AirDocsViewer-release.apk
```

Private GitHub repo: `https://github.com/privatekeyagent2552/AirDocViewer`

---

## 4. Build Commands Cheat Sheet

```bash
# Setup
flutter pub get
dart run pdfrx:remove_wasm_modules          # REQUIRED before Android release builds
dart run build_runner build --delete-conflicting-outputs   # after Hive model changes

# Run
flutter run

# Release APK (CLI)
flutter build apk --release --split-per-abi --target-platform android-arm64

# Regenerate branding
python tools/_apply_logo.py
dart run flutter_launcher_icons
dart run flutter_native_splash:create

# Analyze
flutter analyze
```

**Output paths:**
- Gradle: `android/app/build/outputs/apk/release/AirDocsViewer-release.apk`
- Also mirrored: `android/app/release/AirDocsViewer-release.apk`
- Flutter CLI: `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

**Install (multiple devices — specify serial):**
```bash
adb -s R58T115Q2KR install -r android/app/release/AirDocsViewer-release.apk
adb uninstall com.airdocsviewer   # if launcher icon cached wrong
```

**Primary test device serial:** `R58T115Q2KR`

---

## 5. Architecture Overview

Clean architecture + Riverpod + go_router.

```
lib/
├── main.dart                         # Hive settings init, FileIntentService, GoRouter
├── config/
│   ├── routing/app_router.dart       # Routes: /, /onboarding, /viewer, /documents, etc.
│   └── theme/                        # AppTheme (light-only currently), theme_provider
├── core/
│   ├── services/storage_service.dart # Private app storage, categories, trash
│   ├── services/thumbnail_generation_service.dart
│   ├── presentation/widgets/         # floating_dock_scaffold, fade_in, connected_sheet
│   └── errors/failures.dart
├── services/
│   └── file_intent_service.dart      # Universal open-from-other-apps
├── features/
│   ├── home/                         # Home, Library, Browse, Trash, What's New, shell
│   ├── onboarding/
│   ├── settings/                     # Hive models, settings UI, locale
│   └── viewer/                       # All document viewing (biggest feature)
└── l10n/                             # 11 languages (.arb + generated)
```

### Layer pattern (viewer feature)

| Layer | Location | Role |
|-------|----------|------|
| Presentation | `features/viewer/presentation/` | Screens, widgets, Riverpod notifiers |
| Domain | `features/viewer/domain/` | Entities, repository interfaces, `supported_formats.dart` |
| Data | `features/viewer/data/` | Parsers, Hive cache, platform channels, repo impl |

### State management

- **Riverpod 3** — use `Notifier` / `AsyncNotifier`, **not** legacy `StateNotifier`
- Providers in `*_providers.dart` files per feature

### Routing

- **go_router** singleton in `app_router.dart` (prevents nav reset on rebuild)
- Routes: `/`, `/onboarding`, `/documents`, `/browse`, `/trash`, `/viewer?path=&name=`, `/settings`, `/whats-new`
- File intents push: `/viewer?path=<encoded>&name=<filename>`

---

## 6. Document Viewing Stack (No LibreOffice)

**Single source of truth for formats:** `lib/features/viewer/domain/supported_formats.dart`

| Format group | Extensions | Viewer | Engine |
|--------------|------------|--------|--------|
| PDF | `.pdf` | `ModernPdfViewer` | `pdfrx` |
| Rich Office (visual) | `.docx`, `.pptx` | `OfficeVisualViewer` / WebView | Offline JS in `assets/viewers/` |
| Structured docs | `.doc`, `.rtf`, `.odt`, `.ott`, `.epub` | `RichStructuredDocumentViewer` | Dart + native POI parsers |
| Presentations (legacy) | `.ppt`, `.odp` | Structured viewer | Native/Dart |
| Spreadsheets | `.xlsx`, `.xls`, `.csv`, `.ods` | `ProfessionalSheetViewer` | **Apache POI** via MethodChannel |
| Images | `.png`, `.jpg`, `.webp`, `.gif`, `.bmp`, `.svg`, `.ico`, `.heic`, etc. | `ImageViewer` | Flutter |
| Video / Audio | `.mp4`, `.mkv`, `.mp3`, `.wav`, etc. | `MediaViewer` / `AudioViewer` | `video_player` |
| Text / Code | `.txt`, `.md`, `.html`, `.json`, `.xml`, `.py`, `.java`, `.dart`, etc. | `TextDocumentViewer` | `highlight` package for syntax |

**Routing logic:** `DocumentViewerFactory.createViewer()` + `ViewerScreen` picks widget by `SupportedFormats.viewerKindOf(ext)`.

**Open strategies** (in `supported_formats.dart`):
- `direct` — show immediately (PDF, images, media)
- `parserFirst` — must parse before display (spreadsheets, legacy docs)
- `visualWithFallback` — try WebView first, fall back to structured parser (DOCX/PPTX)

### WebView assets (`assets/viewers/`)

| File | Purpose |
|------|---------|
| `docx.html` + `docx-preview.js` | DOCX visual rendering |
| `pptx.html` + `pptx-renderer.browser.js` + `jszip.min.js` | PPTX slide rendering |
| `office_glyph_fix.js` | Bullet/symbol normalization (referenced from HTML) |

### Office glyph sanitization (Symbol/Wingdings bullets)

Applied in three places — keep in sync when changing Office pipelines:
- Dart: `lib/features/viewer/data/services/office_glyph_sanitizer.dart`
- JS: `assets/viewers/office_glyph_fix.js`
- Kotlin: `android/.../OfficeGlyphSanitizer.kt`

---

## 7. Android Native Layer (Kotlin)

**Location:** `android/app/src/main/kotlin/com/airdocsviewer/`

| File | Role |
|------|------|
| `MainActivity.kt` | MethodChannels, file intents, PDF renderer — **zero direct POI imports** (reflection) |
| `NativeDocumentParser.kt` | POI parsing: XLSX/XLS/CSV/DOC/RTF/etc. |
| `PdfTextExtractor.kt` | PDFBox text extraction for search |
| `SecurityUtils.kt` | Path validation before native reads |
| `OfficeGlyphSanitizer.kt` | Native glyph cleanup |
| `AirDocsViewerApplication.kt` | Pre-warms FlutterEngine + background PDFBox init |

### MethodChannels

| Channel | Dart side | Purpose |
|---------|-----------|---------|
| `com.airdocsviewer/document_parser` | `platform_channel_service.dart` | Native document parse |
| `com.airdocsviewer/file_intent` | `file_intent_service.dart` | Open file from other apps |
| `com.airdocsviewer/pdf` | (viewer/pdf code) | Native PDF page render / text |

### Startup optimization

1. `AirDocsViewerApplication` pre-caches FlutterEngine as `"air_docs_viewer_engine"`
2. `MainActivity.provideFlutterEngine()` returns cached engine
3. Heavy POI/PDFBox loaded via **reflection** on background threads when channel is called
4. ProGuard rules in `android/app/proguard-rules.pro` keep reflection targets

### Native dependencies (Gradle)

- Apache POI 5.2.3 (+ ooxml-full, scratchpad)
- PDFBox Android 2.0.27.0
- XMLBeans, commons-io, commons-codec, commons-logging

---

## 8. Universal App — Opening Files From Other Apps

The app registers as a **default handler** for dozens of MIME types and file extensions in `AndroidManifest.xml`.

**Flow:**
1. User taps PDF/DOCX/etc. in Files app → "Open with AirDoc Viewer"
2. `MainActivity` receives `ACTION_VIEW` intent
3. Kotlin copies/resolves URI to readable path, stores pending intent
4. `FileIntentService` (Dart) polls `getOpenFileIntent` on cold start OR receives `onFileIntent` push on warm start
5. `main.dart` listener navigates: `_router.push('/viewer?path=...&name=...')`

**Key files:**
- `android/app/src/main/AndroidManifest.xml` — all intent-filters
- `MainActivity.kt` — `handleFileIntent()`, URI → file path
- `lib/services/file_intent_service.dart`
- `lib/main.dart` — stream subscription in `initState`

**SupportedFormats** must stay aligned with manifest — never advertise an extension the app can't open.

---

## 9. Storage Model

**Private app storage:** `/storage/emulated/0/Android/data/com.airdocsviewer/files/`

Managed by `lib/core/services/storage_service.dart`:

| Folder | Content |
|--------|---------|
| `PDFs/` | PDF files |
| `Documents/` | DOCX, DOC, TXT, etc. |
| `Spreadsheets/` | XLSX, CSV, etc. |
| `Presentations/` | PPTX, PPT, etc. |
| `Images/` | Image files |
| `Audio/` / `Video/` | Media |
| `Code/` | Code files |
| `Scans/` | Scanned docs |
| `Trash/` | Soft-deleted files (visible folder, not system trash) |

**Import paths:**
- Home screen import card → `file_picker`
- Open from other app → intent (may copy into app storage)
- Browse screen → can scan device with storage permission

**Export:** Save to Downloads (`Download/AirDocsViewer/`) or custom location via SAF.

---

## 10. Hive Local Database

**Models:** `lib/features/settings/data/models/hive_models.dart`  
**Generated:** `hive_models.g.dart` (regenerate with build_runner)

| TypeId | Class | Box | When opened |
|--------|-------|-----|-------------|
| 0 | `HiveRecentFile` | `recent_files` | Deferred (not in main) |
| 1 | `HiveAppSettings` | `settings` | **Opened in main()** |
| 2 | `HiveDeviceInfo` | — | Future cloud sync |
| 3 | `HiveThumbnail` | `cache` | Deferred |

**Settings fields:** theme, language, onboarding flags, notifications, autoUpdateCheck (disabled stub).

**Recent file fields:** path, name, type, size, dates, page position, soft delete, read status, time spent, OCR text placeholder.

**Critical gotcha:** If you add `@HiveField` without regenerating `.g.dart`, Hive **silently drops** the new fields.

---

## 11. UI / Screens

### Main shell (`MainShell`)

- Bottom dock: **Home** tab + **Library** tab
- Double-back to exit on Home
- Library has search mode in app bar

### Home screen (`home_screen.dart`) — ~2273 lines

**User confirmed home logo display is PERFECT — do not change without asking.**

- Fixed logo hero at top: `assets/air_docs_logo.png` (~70% screen width, 16px radius)
- Logo is **outside** scroll view (stays fixed)
- Stats card, import action, recent files list with thumbnails
- File actions: rename, duplicate, export, save to Downloads, soft delete, info dialog
- Skeleton loading on first frame (deferred data load via `addPostFrameCallback`)

### Other screens

| Screen | Path | Notes |
|--------|------|-------|
| Onboarding | `/onboarding` | First launch or re-show from settings |
| Documents / Library | tab + `/documents` | Full library with categories |
| Browse | `/browse` | Device file discovery |
| Trash | `/trash` | Soft-deleted files |
| Viewer | `/viewer` | Main document viewer (~2700 lines) |
| Settings | `/settings` | Language, theme (light-only enforced), privacy, about |
| What's New | `/whats-new` | Feature changelog |

### Viewer screen highlights

- Sidebar with inverted rounded corners ("flares") — see AGENTS.md
- PDF: zoom, page nav, text search, invert colors, text mode
- Spreadsheets: sheet tabs, cell selection, zoom toolbar
- Media: video_player controls
- Fullscreen mode, reading time estimate
- Uses `GlobalKey` for `ModernPdfViewer` (pdfrx state persistence)
- `RepaintBoundary` around heavy viewers

### Theme

- **Light-only** enforced in `main.dart`: `themeMode: ThemeMode.light`, dark theme = light theme copy
- Font: **Ubuntu** (`assets/ubuntu_regular.ttf`)
- Global text scale bump: 1.15× (clamped 1.1–1.45) in `MaterialApp.router` builder

---

## 12. Branding & Logo Assets

**Brand color:** `#08251F` (dark forest green)

| Asset | Used for | Notes |
|-------|----------|-------|
| `assets/_logo_raw.png` | Source master | Input to pipeline |
| `assets/air_docs_logo.png` | **Home screen hero** | Exact original — DO NOT process |
| `assets/air_docs_launcher.png` | App icon | 58% fit for Android circle mask |
| `assets/air_docs_adaptive_fg.png` | Adaptive icon foreground | Same as launcher |
| `assets/air_docs_logo_splash.png` | Splash (2048px) | 72% fit, full text visible |
| `assets/air_docs_emblem.png` | Smaller emblem (512px) | Derived |
| `assets/air_docs_logo_source.png` | Copy of original | Reference |

**Pipeline:** `python tools/_apply_logo.py`
1. Home gets unmodified `_logo_raw.png`
2. Icon/splash: crop to silver content, flatten green bg, fit in safe zone for circular mask
3. Writes `_logo_bg.txt` with sampled hex color

**pubspec.yaml branding:**
```yaml
flutter_native_splash:
  color: "#08251F"
  image: "assets/air_docs_logo_splash.png"
  android_12:
    color: "#08251F"
    image: "assets/air_docs_logo_splash.png"

flutter_launcher_icons:
  image_path: "assets/air_docs_launcher.png"
  adaptive_icon_foreground: "assets/air_docs_adaptive_fg.png"
  adaptive_icon_background: "#08251F"
  adaptive_icon_foreground_inset: 14
```

**After logo changes:** run `_apply_logo.py` → `flutter_launcher_icons` → `flutter_native_splash:create` → rebuild → reinstall (uninstall if icon cached).

---

## 13. Localization (11 Languages)

ARB files in `lib/l10n/`:
`en`, `es`, `fr`, `de`, `pt`, `ru`, `zh`, `ja`, `ar`, `hi`, `ur`

- Never hardcode user-facing strings — use `AppLocalizations.of(context)!`
- Generated code: `lib/l10n/app_localizations*.dart`
- `flutter: generate: true` in pubspec

---

## 14. Key Dependencies (pubspec.yaml)

| Package | Use |
|---------|-----|
| `flutter_riverpod` | State |
| `go_router` | Navigation |
| `pdfrx` | PDF viewing (remove WASM before Android build) |
| `hive` / `hive_flutter` | Local DB |
| `file_picker` | Import |
| `path_provider` | Storage paths |
| `webview_flutter` | DOCX/PPTX |
| `video_player` | Media |
| `permission_handler` | Storage permissions |
| `logger` | Logging (use everywhere for debug) |
| `highlight` | Code syntax highlighting |
| `archive` + `xml` | ODF/OOXML Dart parsing |
| `fl_chart` | Charts in spreadsheets |
| `flutter_launcher_icons` / `flutter_native_splash` | Branding |

---

## 15. Permissions & Privacy

**Release manifest:**
- `INTERNET` — **removed** via `tools:node="remove"`
- `READ_EXTERNAL_STORAGE` — maxSdk 32
- `WRITE_EXTERNAL_STORAGE` — maxSdk 29
- `MANAGE_EXTERNAL_STORAGE` — for Browse full-device discovery
- Strips `READ_MEDIA_*` from dependencies

**Privacy policy:** [PRIVACY.md](PRIVACY.md)

**Non-goals:**
- No analytics SDKs
- No ads
- No external URL launching (clipboard copy instead)
- Update check UI exists but service is **disabled stub**

---

## 16. Important Gotchas & Lessons

### pdfrx
- Run `dart run pdfrx:remove_wasm_modules` before release (saves ~4MB WASM)
- Null check in LayoutBuilder if parent rebuilds destroys state → use `GlobalKey<State<ModernPdfViewer>>` + `RepaintBoundary`

### Animations
- **Never** use `TweenAnimationBuilder` for prop-driven animations — use `AnimationController` + `didUpdateWidget`
- Keep `BackdropFilter` sigma ≤ 8

### Hive
- Only open `settings` in `main()`; defer `recent_files` and `cache`
- Regenerate adapters after any `@HiveField` change

### Android
- `MainActivity` must not import POI directly — reflection only
- R8 full mode enabled; maintain proguard rules
- Multiple adb devices → always pass `-s <serial>`

### Logo / icon
- Android 12+ splash uses **circular mask** — logo must fit inside circle
- Launcher label shows "AirDoc Viewer" from system — icon graphic also has embedded text (user wants both visible)
- Home logo uses **original unprocessed** file — different from icon/splash assets

### Git / secrets
- `upload-keystore.jks`, `key.properties`, `keystore-credentials.txt` are **gitignored**
- `tasks/` folder is gitignored (local agent todos/lessons)

---

## 17. Removed Legacy (Do Not Reintroduce)

| Removed | Notes |
|---------|-------|
| LibreOfficeKit | Was ~346MB; entire `android/app/src/main/assets/program/` tree deleted |
| Fadocx branding | Old product name |
| GitHub update feed | `UpdateCheckService` is no-op |
| External browser/email links | Clipboard only |
| `excel` Dart package | XLSX now native POI only |

Stale docs under `docs/` or `.opencode/` are historical — trust this file + README.

---

## 18. Key File Index (Quick Lookup)

| Need to change… | File |
|-----------------|------|
| App name on launcher | `android/app/build.gradle.kts` → `manifestPlaceholders["appName"]` |
| Supported formats | `lib/features/viewer/domain/supported_formats.dart` + manifest intent-filters |
| Add intent MIME type | `android/app/src/main/AndroidManifest.xml` |
| File open from other apps | `MainActivity.kt` + `file_intent_service.dart` |
| Storage paths | `lib/core/services/storage_service.dart` |
| Routes | `lib/config/routing/app_router.dart` |
| Home UI / logo | `lib/features/home/presentation/screens/home_screen.dart` |
| Viewer UI | `lib/features/viewer/presentation/screens/viewer_screen.dart` |
| Native parsing | `NativeDocumentParser.kt` |
| ProGuard keeps | `android/app/proguard-rules.pro` |
| Signing | `android/key.properties` + `upload-keystore.jks` |
| Logo pipeline | `tools/_apply_logo.py` |
| User strings | `lib/l10n/app_en.arb` (+ other locales) |
| Settings / Hive | `hive_models.dart`, `hive_datasource.dart` |
| Agent workflow rules | `AGENTS.md` |

---

## 19. Agent Workflow (from AGENTS.md)

1. **Plan first** for non-trivial tasks → write to `tasks/todo.md`
2. **Verify** with `flutter analyze` and real device testing
3. **Minimal diffs** — don't rewrite large files unnecessarily
4. **Log** with `package:logger/logger.dart`
5. After user corrections → update `tasks/lessons.md`
6. Read README before assuming LibreOffice or old architecture

---

## 20. Third-Party & Legal

- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — Apache POI, PDFBox, pdfrx, JS viewers, etc.
- © 2026 Crypto Sys Development

---

## 21. How the App Is "Universal"

Air Docs Viewer acts as a **system-wide document handler**:

1. **Intent filters** in manifest cover MIME types + `file://` path patterns for every supported extension
2. **Openable from:** Files app, downloads, email attachments, file managers, share → open with
3. **SingleTop launch mode** — reuses activity for new intents (`onNewIntent`)
4. **Format registry** ensures every advertised type has a real viewer implementation
5. **Security** — native layer validates paths via `SecurityUtils.isSafeReadablePath()` before parsing

This is the Android equivalent of being registered as a universal file viewer — not a separate "instant app" or web wrapper.

---

## 22. Current Known-Good State (July 2026)

- Home screen logo: **approved by user** (`air_docs_logo.png`, fixed hero, no height clamp)
- Icon + splash: full "AirDoc Viewer" text visible after `_apply_logo.py` 58%/72% fit + inset 14
- Release APK ~75–80 MB, arm64 only
- Test device: `R58T115Q2KR`
- Version code 6, version name 1.0.0

---

*End of project memory. When in doubt, search this file and README.md before editing.*
