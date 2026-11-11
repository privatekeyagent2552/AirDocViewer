# Air Docs Viewer — Build Guide

## Quick start

```bash
flutter pub get
dart run pdfrx:remove_wasm_modules
flutter run
```

## Package

| Item | Value |
|------|--------|
| App | AirDoc Viewer |
| Flutter package | `air_docs_viewer` |
| Android ID | `com.airdocsviewer` |
| ABI | `arm64-v8a` + `armeabi-v7a` in **`AirDocsViewer-release.apk`** |
| Min SDK | 26 |
| Release APK name | **`AirDocsViewer-release.apk`** |

## Signed release APK

### Prerequisites (local only — gitignored)

1. `android/upload-keystore.jks`
2. `android/key.properties` (alias `airdocsviewer` + passwords)
3. Optional notes: `android/keystore-credentials.txt`

### Flutter CLI

```bash
dart run pdfrx:remove_wasm_modules
flutter build apk --release
```

Copy / IDE path:

`android/app/release/AirDocsViewer-release.apk`

32-bit + 64-bit ARM phones (default):

```bash
flutter build apk --release --target-platform android-arm,android-arm64
```

### Android Studio

**Build → Generate Signed App Bundle or APK** → APK → release → keystore `upload-keystore.jks` → alias `airdocsviewer`.

Gradle forces output names:

- `AirDocsViewer-release.apk`
- `AirDocsViewer-debug.apk`

### Install

```bash
adb install -r android/app/release/AirDocsViewer-release.apk
adb uninstall com.airdocsviewer
```

## Notes

- Release size roughly **~85–90 MB** (32-bit + 64-bit ARM)
- R8 + resource shrinking enabled for release
- Before release: `dart run pdfrx:remove_wasm_modules`
- After Hive changes: `dart run build_runner build --delete-conflicting-outputs`
- Full project memory: [PROJECT_MEMORY.md](PROJECT_MEMORY.md)
- Root overview: [README.md](README.md)
