# Third-Party Notices — Air Docs Viewer

This application includes open-source components. Copyright belongs to the respective authors.

## Android / JVM libraries
- Apache POI (`org.apache.poi`) — Apache License 2.0
- Apache XMLBeans — Apache License 2.0
- Apache Commons IO / Codec / Logging — Apache License 2.0
- PDFBox Android (`com.tom-roush:pdfbox-android`) — Apache License 2.0

## Bundled offline Office renderers (`assets/viewers/`)
- [docx-preview / docxjs](https://github.com/VolodymyrBaydalka/docxjs) (`docx-preview.js`) — Apache License 2.0
- [JSZip](https://github.com/Stuk/jszip) (`jszip.min.js`) — MIT / GPLv3 dual license
- [@aiden0z/pptx-renderer](https://github.com/aiden0z/pptx-renderer) (`pptx-renderer.browser.js`) — Apache License 2.0

These scripts run inside an Android WebView from local staged files only. Document bytes are injected through a JavaScript channel; remote navigation is blocked. Legacy `.doc` / `.ppt` are not rendered by these engines (structured parsers are used instead).

## Flutter packages (general)
See `pubspec.yaml` and run `flutter pub licenses` for the full dependency license list (Riverpod, Hive, pdfrx, webview_flutter, video_player, file_picker, and others).

Air Docs Viewer itself is licensed under GPLv3 — see `LICENSE`.
