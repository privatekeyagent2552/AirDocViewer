# Third-Party Notices — Air Docs Viewer

This application includes open-source components. Copyright belongs to the respective authors.

## Android / JVM libraries
- Apache POI (`org.apache.poi`) — Apache License 2.0
- Apache XMLBeans — Apache License 2.0
- Apache Commons IO / Codec / Logging — Apache License 2.0
- PDFBox Android (`com.tom-roush:pdfbox-android`) — Apache License 2.0

## Bundled offline Office renderers (`assets/viewers/`)
- [docx-preview / docxjs](https://github.com/VolodymyrBaydalka/docxjs) (`docx-preview.js`) — Apache License 2.0
- [JSZip](https://github.com/Stuk/jszip) (`jszip.min.js`, `pptxjs/jszip2.min.js`) — MIT / GPLv3 dual license
- [PPTXjs](https://github.com/meshesha/PPTXjs) + [divs2slides](https://github.com/meshesha/PPTXjs) (`assets/viewers/pptxjs/`) — MIT
- [jQuery](https://jquery.org/) 1.11 (`pptxjs/jquery.min.js`) — MIT
- [D3](https://d3js.org/) 3.x (`pptxjs/d3.min.js`) — BSD-3-Clause
- [NVD3](https://nvd3.org/) (`pptxjs/nv.d3.min.js`) — Apache License 2.0

These scripts run inside an Android WebView from local staged files only. Document bytes are injected through a JavaScript channel; remote navigation is blocked. Legacy `.doc` / `.ppt` are not rendered by these engines (structured parsers are used instead). PPTX slide fidelity uses the same PPTXjs stack as [Gander](https://github.com/mokshablr/gander) (MIT).

## Flutter packages (general)
See `pubspec.yaml` and run `flutter pub licenses` for the full dependency license list (Riverpod, Hive, pdfrx, webview_flutter, video_player, file_picker, and others).

Air Docs Viewer itself is licensed under GPLv3 — see `LICENSE`.
