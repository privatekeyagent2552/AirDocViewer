# Supported & Blocked File Types (VAPT)

**App:** AirDoc Viewer (`com.airdocsviewer`)  
**Policy:** Strict allowlist — only the extensions below may be imported, picked, viewed, or opened via Android intents. Everything else is rejected.

---

## Supported (allowed import / upload / open)

| Category | Extensions |
|----------|------------|
| PDF | `.pdf` |
| Word | `.doc`, `.docx` |
| PowerPoint | `.ppt`, `.pptx` |
| Excel | `.xls`, `.xlsx`, `.csv` |
| Text | `.txt` |

**Exact allowlist:** `pdf`, `doc`, `docx`, `ppt`, `pptx`, `xls`, `xlsx`, `csv`, `txt`

---

## Blocked / restricted

| Category | Examples (not exhaustive) |
|----------|---------------------------|
| Executables / installers | `.exe`, `.dll`, `.msi`, `.apk`, `.jar`, `.so`, `.bin`, `.scr`, … |
| Scripts / shells | `.bat`, `.cmd`, `.ps1`, `.vbs`, `.js`, `.sh`, `.bash`, … |
| Source / runtime code | `.py`, `.java`, `.php`, `.rb`, `.kt`, `.dart`, `.ts`, … |
| Archives | `.zip`, `.rar`, `.7z`, `.tar`, `.gz`, … |
| Images | `.png`, `.jpg`, `.gif`, `.webp`, `.bmp`, `.svg`, … |
| Audio / video | `.mp3`, `.mp4`, `.mkv`, `.avi`, `.wav`, … |
| Other office / docs | `.odt`, `.ods`, `.odp`, `.rtf`, `.epub`, … |
| Web / data | `.html`, `.htm`, `.md`, `.json`, `.xml`, … |

**Rule:** Any extension **not** on the allowlist is rejected, even if it is not listed in the explicit blocklist.

---

## Extra malware protections

| Control | Behavior |
|---------|----------|
| Extension allowlist | Import / picker / viewer / system open |
| Explicit blocklist | Executables, scripts, archives, media, etc. |
| Magic-byte check | Content must match claimed type (e.g. fake `.pdf` that is really `.exe` is rejected) |
| Size cap | Max **200 MB** per import |
| Storage | Private app storage only |
| Network | No internet permission in release — no upload |

---

## Code sources of truth

| Layer | File |
|-------|------|
| Flutter allowlist | `lib/features/viewer/domain/supported_formats.dart` |
| Flutter validation | `lib/core/services/file_security_validator.dart` |
| Android validation | `android/app/src/main/kotlin/com/airdocsviewer/SecurityUtils.kt` |
| Intent filters | `android/app/src/main/AndroidManifest.xml` |

© 2026 Dte of Crypto Sys Dev
