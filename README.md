# AirDoc Viewer (Air Docs Viewer)

Offline document viewer for Android — **PDF, Word, PowerPoint, Excel, CSV, and TXT only** (strict allowlist).

**Private repo:** [privatekeyagent2552/AirDocViewer](https://github.com/privatekeyagent2552/AirDocViewer)  
**Developer credit (in-app):** Developed by **Dte of Crypto Sys Dev**

> **For AI / Cursor agents:** Read this file **and** [PROJECT_MEMORY.md](PROJECT_MEMORY.md) first. Do **not** assume LibreOffice, Fadocx branding, or GitHub release feeds — those are outdated.

---

## App identity

| Item | Value |
|------|--------|
| Launcher label | **AirDoc Viewer** |
| Flutter package | `air_docs_viewer` |
| Android `applicationId` | `com.airdocsviewer` |
| Version name | `1.0.0` |
| Version code | `6` (`android/app/build.gradle.kts`) |
| Min SDK | **26** (Android 8.0+) |
| Primary ABI | `arm64-v8a` + `armeabi-v7a` (single `AirDocsViewer-release.apk`) |
| Release APK name | **`AirDocsViewer-release.apk`** |
| Debug APK name | **`AirDocsViewer-debug.apk`** |

---

## Features

- View **9 approved document formats** offline (strict VAPT allowlist)
- **Private app storage** under `Android/data/com.airdocsviewer/`
- **Universal opener** — Android intent filters for allowlisted types only
- Library with categories, search, thumbnails, trash, recent files
- Import via `file_picker` / SAF (allowlisted extensions only)
- In-document search (PDF, text, sheets, Office where supported)
- **11 languages** (ARB)
- No ads, no analytics SDKs
- Strict offline release: `INTERNET` stripped from the main manifest

---

## Supported formats

| Category | Formats |
|----------|---------|
| PDF | `.pdf` |
| Documents | `.doc`, `.docx`, `.txt` |
| Spreadsheets | `.xls`, `.xlsx`, `.csv` |
| Presentations | `.ppt`, `.pptx` |

**Everything else is blocked** (executables, scripts, images, media, archives, HTML, code, OpenDocument, etc.).

Full supported / blocked tables: [SUPPORTED_FILE_TYPES.md](SUPPORTED_FILE_TYPES.md)  
Canonical registry: `lib/features/viewer/domain/supported_formats.dart`

---

## Document stack (no LibreOffice)

| Format | Engine |
|--------|--------|
| PDF | `pdfrx` → `ModernPdfViewer` |
| DOCX / PPTX | WebView + offline JS (`assets/viewers/`) |
| DOC / PPT | Structured Dart/native parsers |
| XLSX / XLS / CSV | Apache **POI** via MethodChannel |
| TXT | `TextDocumentViewer` |

---

## Architecture

```
lib/
├── main.dart
├── config/          # theme, go_router
├── core/            # storage, widgets, layout
├── services/        # file intents (universal open)
├── features/
│   ├── home/        # Home, Library, Browse, Trash, MainShell
│   ├── onboarding/
│   ├── settings/    # Hive models + UI
│   └── viewer/      # parsers + viewers
└── l10n/            # 11 languages
```

State: **Riverpod** · Routing: **go_router** · Local DB: **Hive**

Agent rules: [AGENTS.md](AGENTS.md) · Full memory: [PROJECT_MEMORY.md](PROJECT_MEMORY.md)

---

## Setup

```bash
flutter pub get
dart run pdfrx:remove_wasm_modules
dart run build_runner build --delete-conflicting-outputs   # after Hive model changes
flutter run
```

---

## Signed release APK (`AirDocsViewer-release.apk`)

### 1. Local signing files (gitignored — never commit)

| File | Purpose |
|------|---------|
| `android/upload-keystore.jks` | Release keystore |
| `android/key.properties` | Passwords + alias for Gradle |
| `android/keystore-credentials.txt` | Human-readable local notes |

**`android/key.properties` template** (create locally; do not commit):

```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=airdocsviewer
storeFile=upload-keystore.jks
```

Key alias: **`airdocsviewer`**

### 2. Option A — Flutter CLI (recommended)

```bash
flutter pub get
dart run pdfrx:remove_wasm_modules
flutter build apk --release
```

Outputs:

- `build/app/outputs/flutter-apk/app-release.apk` (Flutter name)
- Copy / IDE mirror: **`android/app/release/AirDocsViewer-release.apk`**

Default release (32-bit + 64-bit ARM, same APK name):

```bash
flutter build apk --release --target-platform android-arm,android-arm64
```

### 3. Option B — Android Studio

1. **Build → Generate Signed App Bundle or APK → APK**
2. Key store: `android/upload-keystore.jks`
3. Alias: `airdocsviewer`
4. Enter store/key passwords from your local `keystore-credentials.txt`
5. Build variant: **release**
6. Destination: `android/app` (Studio writes into `android/app/release/`)

Gradle renames the file via `android/app/build.gradle.kts`:

```text
AirDocsViewer-release.apk
AirDocsViewer-debug.apk
```

### 4. Where to find the shipping APK

| Path | Notes |
|------|--------|
| **`android/app/release/AirDocsViewer-release.apk`** | Preferred share / install path |
| `build/app/outputs/flutter-apk/app-release.apk` | Flutter CLI fat APK (same content when copied) |

Typical size: ~**85–90 MB** (32-bit + 64-bit ARM). No LibreOffice.

### 5. Verify signing

```bash
apksigner verify --print-certs android/app/release/AirDocsViewer-release.apk
```

Expect signer CN like **Air Docs Viewer**, package `com.airdocsviewer`, version `1.0.0` / code `6`.

### 6. Install

```bash
adb install -r android/app/release/AirDocsViewer-release.apk
# if multiple devices:
adb -s DEVICE_SERIAL install -r android/app/release/AirDocsViewer-release.apk
```

---

## Branding / logo assets

| Asset | Use |
|-------|-----|
| `assets/air_docs_logo.png` | Home screen hero |
| `assets/air_docs_launcher.png` | App icon |
| `assets/air_docs_logo_splash.png` | Splash (home-style layout) |

Regenerate after logo changes:

```bash
python tools/_apply_logo.py
dart run flutter_launcher_icons
dart run flutter_native_splash:create
```

Splash/icon background: `#08251F`

---

## Analyze

```bash
flutter analyze
```

More build notes: [BUILD_GUIDE.md](BUILD_GUIDE.md) · Privacy: [PRIVACY.md](PRIVACY.md) · Supported/blocked types: [SUPPORTED_FILE_TYPES.md](SUPPORTED_FILE_TYPES.md)

---

## Intentional non-goals

- No LibreOffice / LibreOfficeKit in the product binary
- No Fadocx branding
- No live update feed
- Do not commit keystore / `key.properties` / passwords

---

## License

Provided as-is.

© 2026 Crypto Sys Development / Dte of Crypto Sys Dev
