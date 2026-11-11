import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'package:air_docs_viewer/l10n/app_localizations.dart';

enum OfficeVisualKind { word, presentation }

/// Offline visual Office viewer for DOCX / PPTX.
///
/// Uses bundled open-source JavaScript renderers loaded from local files only.
/// Document bytes are transferred over a JS channel in base64 chunks so the
/// WebView never needs network or `fetch('file://…')`.
class OfficeVisualViewer extends StatefulWidget {
  const OfficeVisualViewer({
    super.key,
    required this.filePath,
    required this.kind,
    this.onRendered,
    this.onError,
    this.onZoomChanged,
    this.backgroundColor,
  });

  final String filePath;
  final OfficeVisualKind kind;
  final VoidCallback? onRendered;
  final void Function(String message)? onError;
  final ValueChanged<double>? onZoomChanged;
  final Color? backgroundColor;

  @override
  State<OfficeVisualViewer> createState() => OfficeVisualViewerState();
}

class OfficeVisualViewerState extends State<OfficeVisualViewer> {
  final _log = Logger();
  late final WebViewController _controller;
  List<String> _chunks = const [];
  String? _error;
  String _status = 'Preparing document…';
  bool _htmlLoaded = false;
  bool _bridgeReady = false;
  bool _started = false;
  bool _triedStagedHtml = false;
  bool _renderedNotified = false;
  bool _legacyOlePpt = false;
  double _zoom = 1.0;

  static const _minZoom = 0.25;
  static const _maxZoom = 3.0;
  /// Larger step so each tap is noticeable (esp. PPT / Word on phones).
  static const _zoomStep = 0.15;

  /// Zoom API for DOCX and PPTX (floating pill hosted by ViewerScreen).
  bool get supportsZoom => true;

  double get currentZoom => _zoom;

  String get _setZoomFn =>
      widget.kind == OfficeVisualKind.word ? 'setDocxZoom' : 'setPptxZoom';

  String get _fitZoomFn =>
      widget.kind == OfficeVisualKind.word ? 'fitDocxToWidth' : 'fitPptxToWidth';

  /// Public API — same pattern as [ModernPdfViewer.zoomIn].
  void zoomIn() {
    if (!supportsZoom) return;
    unawaited(_zoomBy(_zoomStep));
  }

  /// Public API — same pattern as [ModernPdfViewer.zoomOut].
  void zoomOut() {
    if (!supportsZoom) return;
    unawaited(_zoomBy(-_zoomStep));
  }

  /// Public API — fit width and reset scroll (same as PDF fitToWidth).
  void fitToWidth() {
    if (!supportsZoom) return;
    unawaited(_fitZoom());
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.backgroundColor ?? const Color(0xFFF5F5F5))
      ..setOnConsoleMessage((message) {
        _log.d('OfficeVisualViewer JS: ${message.message}');
      })
      ..addJavaScriptChannel(
        'AirDocsViewer',
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final url = request.url;
            if (url.startsWith('file://') ||
                url.startsWith('about:') ||
                url.startsWith('data:')) {
              return NavigationDecision.navigate;
            }
            _log.w('Blocked remote navigation: $url');
            return NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            final url = (error.url ?? '').toLowerCase();
            // Script/font/subframe errors must not abort PPTX.
            if (error.isForMainFrame != true) {
              _log.w(
                'Ignored WebView resource error '
                '(mainFrame=${error.isForMainFrame}): ${error.description} $url',
              );
              return;
            }
            if (url.contains('about:blank') || url.isEmpty && _chunks.isEmpty) {
              _log.w(
                'Ignored main-frame error before viewer html: '
                '${error.description} $url',
              );
              return;
            }
            if (_chunks.isEmpty) {
              _log.w(
                'Ignored main-frame error during prepare: ${error.description}',
              );
              return;
            }
            if (!_triedStagedHtml && !_isViewerHtmlUrl(url) && url.isNotEmpty) {
              _log.w(
                'Ignored main-frame error on non-viewer url: '
                '${error.description} $url',
              );
              return;
            }
            if (!_triedStagedHtml) {
              unawaited(_reloadFromStaging());
              return;
            }
            _fail('WebView error: ${error.description}');
          },
          onPageFinished: (url) {
            if (!_isViewerHtmlUrl(url)) {
              _log.d('Ignore page finished (not viewer html): $url');
              return;
            }
            _htmlLoaded = true;
            unawaited(_startRender());
          },
        ),
      );
    _prepare();
  }

  String get _htmlAssetName => widget.kind == OfficeVisualKind.word
      ? 'docx.html'
      : 'pptx.html';

  String get _htmlAssetKey => 'assets/viewers/$_htmlAssetName';

  bool _isViewerHtmlUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains(_htmlAssetName.toLowerCase());
  }

  Future<void> _prepare() async {
    try {
      if (_controller.platform is AndroidWebViewController) {
        final android = _controller.platform as AndroidWebViewController;
        await android.setAllowFileAccess(true);
        await android.setMediaPlaybackRequiresUserGesture(false);
        // DOCX + PPTX: disable browser page-zoom so pinch uses our JS zoom path.
        await android.enableZoom(false);
        // DomStorage is enabled by default in webview_flutter_android (API 26+).
      }

      // Detect OLE (.ppt) vs ZIP (.pptx). Only OLE uses text slide-cards.
      if (widget.kind == OfficeVisualKind.presentation) {
        final header =
            await File(widget.filePath).openRead(0, 8).fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        final isOle = header.length >= 4 &&
            header[0] == 0xD0 &&
            header[1] == 0xCF &&
            header[2] == 0x11 &&
            header[3] == 0xE0;
        final isZip = header.length >= 2 &&
            header[0] == 0x50 &&
            header[1] == 0x4B;
        if (isOle) {
          _legacyOlePpt = true;
          _fail(
            'Legacy .ppt cannot show slide design offline. '
            'Save as .pptx for colors, charts, and layout.',
          );
          return;
        }
        if (!isZip) {
          _fail('This file is not a valid .pptx (expected ZIP/OOXML).');
          return;
        }
      }

      final bytes = await File(widget.filePath).readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('File is empty: ${widget.filePath}');
      }
      _chunks = await compute(_encodeChunks, bytes);

      if (!mounted) return;
      setState(() {
        _status = widget.kind == OfficeVisualKind.word
            ? 'Opening document…'
            : 'Opening presentation…';
      });
      await _loadViewerHtml();
      // onPageFinished can race loadFlutterAsset; try start either way.
      unawaited(_startRender());
      _log.d(
        'OfficeVisualViewer html loaded kind=${widget.kind.name} '
        'chunks=${_chunks.length}',
      );
    } catch (e, st) {
      _log.e('Office visual prepare failed: $e', error: e, stackTrace: st);
      _fail(e.toString());
    }
  }

  Future<void> _loadViewerHtml() async {
    // PPTX loads 7 local scripts via relative paths — stage the folder so
    // file:// resolution matches Gander's PPTXjs layout.
    if (widget.kind == OfficeVisualKind.presentation) {
      _triedStagedHtml = true;
      final staging = await _stageViewerFiles();
      final htmlPath =
          '${staging.path}${Platform.pathSeparator}$_htmlAssetName';
      await _controller.loadFile(htmlPath);
      _log.d('OfficeVisualViewer staged PPTX $htmlPath');
      return;
    }
    try {
      await _controller.loadFlutterAsset(_htmlAssetKey);
      _log.d('OfficeVisualViewer loadFlutterAsset $_htmlAssetKey');
    } catch (e, st) {
      _log.w(
        'loadFlutterAsset failed, staging files: $e',
        error: e,
        stackTrace: st,
      );
      final staging = await _stageViewerFiles();
      final htmlPath =
          '${staging.path}${Platform.pathSeparator}$_htmlAssetName';
      await _controller.loadFile(htmlPath);
      _log.d('OfficeVisualViewer loadFile $htmlPath');
    }
  }

  Future<Directory> _stageViewerFiles() async {
    final temp = await getTemporaryDirectory();
    final dir = Directory(
      '${temp.path}${Platform.pathSeparator}airdocs_office_viewers',
    );
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final assets = widget.kind == OfficeVisualKind.word
        ? const ['docx.html', 'jszip.min.js', 'docx-preview.js']
        : const [
            'pptx.html',
            'pptxjs/jquery.min.js',
            'pptxjs/jszip2.min.js',
            'pptxjs/filereader.js',
            'pptxjs/d3.min.js',
            'pptxjs/nv.d3.min.js',
            'pptxjs/pptxjs.js',
            'pptxjs/divs2slides.js',
            'pptxjs/pptxjs.css',
            'pptxjs/nv.d3.min.css',
          ];

    for (final name in assets) {
      final out = File(
        '${dir.path}${Platform.pathSeparator}${name.replaceAll('/', Platform.pathSeparator)}',
      );
      await out.parent.create(recursive: true);
      final data = await rootBundle.load('assets/viewers/$name');
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir;
  }

  Future<void> _startRender() async {
    if (_started || _chunks.isEmpty) return;
    if (!_bridgeReady && !_htmlLoaded) return;

    final starter = widget.kind == OfficeVisualKind.word
        ? 'startOfflineDocx'
        : 'startOfflinePptx';
    try {
      final exists = await _controller.runJavaScriptReturningResult(
        '(typeof window.$starter === "function")',
      );
      if (!exists.toString().contains('true')) {
        final pending = widget.kind == OfficeVisualKind.word
            ? '__pendingDocxChunks'
            : '__pendingPptxChunks';
        await _controller.runJavaScript(
          'window.$pending = ${_chunks.length};',
        );
        _log.d('OfficeVisualViewer queued $pending=${_chunks.length}');
        return;
      }
      _started = true;
      await _controller.runJavaScript(
        'window.$starter(${_chunks.length});',
      );
    } catch (e, st) {
      _started = false;
      _log.w('Office visual start not ready: $e', error: e, stackTrace: st);
      // Do not fail the deck on a race; bridgeReady / page-finished will retry.
      if (_bridgeReady && _htmlLoaded) {
        _fail(e.toString());
      }
    }
  }

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    try {
      final payload = jsonDecode(message.message) as Map<String, dynamic>;
      final type = payload['type'] as String?;
      switch (type) {
        case 'getChunk':
          final index = payload['index'] as int? ?? -1;
          final requestId = payload['requestId'] as String? ?? '';
          if (index < 0 || index >= _chunks.length || requestId.isEmpty) {
            _fail('Invalid document chunk request');
            return;
          }
          final chunk = jsonEncode(_chunks[index]);
          await _controller.runJavaScript(
            'window.receiveDocChunk(${jsonEncode(requestId)}, $chunk);',
          );
          break;
        case 'bridgeReady':
          _bridgeReady = true;
          unawaited(_startRender());
          break;
        case 'status':
          final text = payload['message'] as String? ?? '';
          if (!mounted) return;
          setState(() => _status = text);
          break;
        case 'rendered':
          if (!_renderedNotified) {
            _renderedNotified = true;
            _log.i('OfficeVisualViewer RENDERED kind=${widget.kind}');
            if (mounted) setState(() => _status = '');
            widget.onRendered?.call();
          }
          break;
        case 'zoom':
          final z = (payload['zoom'] as num?)?.toDouble();
          if (z != null && mounted) {
            final next = z.clamp(_minZoom, _maxZoom);
            setState(() => _zoom = next);
            widget.onZoomChanged?.call(next);
          }
          break;
        case 'error':
          final message =
              payload['message']?.toString() ?? 'Render failed';
          if (_shouldRetryStagedLoad(message)) {
            unawaited(_reloadFromStaging());
            return;
          }
          _fail(message);
          break;
      }
    } catch (e, st) {
      _log.e('Office bridge message failed: $e', error: e, stackTrace: st);
      _fail(e.toString());
    }
  }

  bool _shouldRetryStagedLoad(String message) {
    if (_triedStagedHtml) return false;
    final lower = message.toLowerCase();
    return lower.contains('failed to load') ||
        lower.contains('could not be loaded') ||
        lower.contains('renderer script');
  }

  Future<void> _reloadFromStaging() async {
    _triedStagedHtml = true;
    _started = false;
    _bridgeReady = false;
    _htmlLoaded = false;
    _log.w('OfficeVisualViewer retrying with staged HTML files');
    if (!mounted) return;
    setState(() {
      _error = null;
      _status = widget.kind == OfficeVisualKind.word
          ? 'Opening document…'
          : 'Opening presentation…';
    });
    try {
      final staging = await _stageViewerFiles();
      final htmlPath =
          '${staging.path}${Platform.pathSeparator}$_htmlAssetName';
      await _controller.loadFile(htmlPath);
    } catch (e, st) {
      _log.e('Staged HTML reload failed: $e', error: e, stackTrace: st);
      _fail(e.toString());
    }
  }

  void _fail(String message) {
    _log.e('OfficeVisualViewer FAIL: $message');
    if (!mounted) return;
    setState(() {
      _error = message;
      _status = '';
    });
    // PPTX (ZIP) stays on this visual surface so we never replace the
    // real deck with fake green/red text cards. Only legacy OLE .ppt
    // asks the parent to switch to the slide-card fallback.
    if (_legacyOlePpt || widget.kind != OfficeVisualKind.presentation) {
      widget.onError?.call(message);
    }
  }

  Future<void> _setZoom(double zoom) async {
    if (!supportsZoom || !_renderedNotified) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    try {
      await _controller.runJavaScript('window.$_setZoomFn($clamped);');
    } catch (e, st) {
      _log.w('Office zoom failed: $e', error: e, stackTrace: st);
    }
  }

  Future<void> _zoomBy(double delta) async {
    if (!supportsZoom || !_renderedNotified) return;
    // Prefer adjust* so PPT uses the renderer's live zoom, not a stale Flutter value.
    final adjustFn = widget.kind == OfficeVisualKind.word
        ? 'adjustDocxZoom'
        : 'adjustPptxZoom';
    try {
      await _controller.runJavaScript('window.$adjustFn($delta);');
    } catch (e, st) {
      _log.w('Office zoomBy failed, falling back: $e', error: e, stackTrace: st);
      await _setZoom(_zoom + delta);
    }
  }

  Future<void> _fitZoom() async {
    if (!supportsZoom || !_renderedNotified) return;
    try {
      await _controller.runJavaScript('window.$_fitZoomFn();');
    } catch (e, st) {
      _log.w('Office fit zoom failed: $e', error: e, stackTrace: st);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor ?? const Color(0xFFF5F5F5);
    if (_error != null) {
      return ColoredBox(
        color: bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return ColoredBox(
      color: bg,
      child: Stack(
        children: [
          Positioned.fill(child: WebViewWidget(controller: _controller)),
          if (_status.isNotEmpty)
            Positioned.fill(
              child: ColoredBox(
                color: bg.withValues(alpha: 0.92),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _status.isEmpty
                            ? AppLocalizations.of(context)!.lokitPreparingDoc
                            : _status,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // Zoom pill is hosted by ViewerScreen (same as PDF) — not drawn here.
        ],
      ),
    );
  }
}

List<String> _encodeChunks(Uint8List bytes) {
  const chunkBytes = 120 * 1024;
  final out = <String>[];
  for (var i = 0; i < bytes.length; i += chunkBytes) {
    final end = (i + chunkBytes < bytes.length) ? i + chunkBytes : bytes.length;
    out.add(base64Encode(bytes.sublist(i, end)));
  }
  return out;
}
