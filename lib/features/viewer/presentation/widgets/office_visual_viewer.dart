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
import 'package:air_docs_viewer/features/viewer/presentation/widgets/viewer_zoom_toolbar.dart';

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
    this.backgroundColor,
  });

  final String filePath;
  final OfficeVisualKind kind;
  final VoidCallback? onRendered;
  final void Function(String message)? onError;
  final Color? backgroundColor;

  @override
  State<OfficeVisualViewer> createState() => _OfficeVisualViewerState();
}

class _OfficeVisualViewerState extends State<OfficeVisualViewer> {
  final _log = Logger();
  late final WebViewController _controller;
  List<String> _chunks = const [];
  String? _error;
  String _status = 'Preparing document…';
  bool _ready = false;
  bool _renderedNotified = false;
  double _zoom = 1.0;

  static const _minZoom = 0.25;
  static const _maxZoom = 3.0;
  /// Larger step so each tap is noticeable (esp. PPT / Word on phones).
  static const _zoomStep = 0.15;

  /// Floating zoom toolbar: Word/DOCX only. PPTX has no on-screen zoom buttons.
  bool get _supportsZoom => widget.kind == OfficeVisualKind.word;

  String get _setZoomFn =>
      widget.kind == OfficeVisualKind.word ? 'setDocxZoom' : 'setPptxZoom';

  String get _fitZoomFn =>
      widget.kind == OfficeVisualKind.word ? 'fitDocxToWidth' : 'fitPptxToWidth';

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
            // Non-main-frame errors (fonts, etc.) should not fail the viewer.
            if (error.isForMainFrame ?? true) {
              _fail('WebView error: ${error.description}');
            } else {
              _log.w('Ignored subframe WebView error: ${error.description}');
            }
          },
          onPageFinished: (_) => _startRender(),
        ),
      );
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      if (_controller.platform is AndroidWebViewController) {
        final android = _controller.platform as AndroidWebViewController;
        await android.setAllowFileAccess(true);
        await android.setMediaPlaybackRequiresUserGesture(false);
        // DomStorage is enabled by default in webview_flutter_android (API 26+).
      }

      final bytes = await File(widget.filePath).readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('File is empty: ${widget.filePath}');
      }
      _chunks = await compute(_encodeChunks, bytes);

      final staging = await _stageViewerFiles();
      final htmlName =
          widget.kind == OfficeVisualKind.word ? 'docx.html' : 'pptx.html';
      final htmlPath = '${staging.path}${Platform.pathSeparator}$htmlName';
      if (!mounted) return;
      setState(() {
        _status = widget.kind == OfficeVisualKind.word
            ? 'Opening document…'
            : 'Opening presentation…';
      });
      await _controller.loadFile(htmlPath);
      _log.d(
        'OfficeVisualViewer loadFile ok kind=${widget.kind.name} '
        'chunks=${_chunks.length} path=$htmlPath',
      );
    } catch (e, st) {
      _log.e('Office visual prepare failed: $e', error: e, stackTrace: st);
      _fail(e.toString());
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
        : const ['pptx.html', 'pptx-renderer.browser.js'];

    for (final name in assets) {
      final out = File('${dir.path}${Platform.pathSeparator}$name');
      final data = await rootBundle.load('assets/viewers/$name');
      await out.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return dir;
  }

  Future<void> _startRender() async {
    if (_ready || _chunks.isEmpty) return;
    _ready = true;
    final starter = widget.kind == OfficeVisualKind.word
        ? 'startOfflineDocx'
        : 'startOfflinePptx';
    try {
      await _controller.runJavaScript('$starter(${_chunks.length});');
    } catch (e, st) {
      _log.e('Office visual start failed: $e', error: e, stackTrace: st);
      _fail(e.toString());
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
            setState(() => _zoom = z.clamp(_minZoom, _maxZoom));
          }
          break;
        case 'error':
          _fail(payload['message']?.toString() ?? 'Render failed');
          break;
      }
    } catch (e, st) {
      _log.e('Office bridge message failed: $e', error: e, stackTrace: st);
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
    widget.onError?.call(message);
  }

  Future<void> _setZoom(double zoom) async {
    if (!_supportsZoom || !_renderedNotified) return;
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    try {
      await _controller.runJavaScript('window.$_setZoomFn($clamped);');
    } catch (e, st) {
      _log.w('Office zoom failed: $e', error: e, stackTrace: st);
    }
  }

  Future<void> _zoomBy(double delta) async {
    if (!_supportsZoom || !_renderedNotified) return;
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
    if (!_supportsZoom || !_renderedNotified) return;
    try {
      await _controller.runJavaScript('window.$_fitZoomFn();');
    } catch (e, st) {
      _log.w('Office fit zoom failed: $e', error: e, stackTrace: st);
    }
  }

  Widget _buildZoomControls(BuildContext context) {
    return ViewerZoomToolbar(
      zoom: _zoom,
      minZoom: _minZoom,
      maxZoom: _maxZoom,
      onZoomOut: () => _zoomBy(-_zoomStep),
      onZoomIn: () => _zoomBy(_zoomStep),
      onFit: _fitZoom,
    );
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
          if (_supportsZoom && _renderedNotified && _status.isEmpty)
            Positioned(
              right: 12,
              // Sit above the viewer bottom panel so taps aren't blocked.
              bottom: 88,
              child: SafeArea(child: _buildZoomControls(context)),
            ),
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
