import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'package:air_docs_viewer/features/viewer/data/services/platform_channel_service.dart';
import 'package:air_docs_viewer/features/viewer/presentation/viewer_failure_message.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

enum OfficeVisualKind { word, presentation }

/// Offline visual Office viewer for DOCX / PPTX.
///
/// DOCX bytes are transferred over a JS channel in base64 chunks.
/// PPTX is paged: one slide's XML package is sent, and only that slide's
/// pictures are written beside the viewer HTML. Moving to another slide
/// drops the previous pictures.
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
  final _slides = MethodChannelService();
  late final WebViewController _controller;
  int _chunkCount = 0;
  static const _chunkBytes = 120 * 1024;
  static const _maxOfficeBytes = 64 * 1024 * 1024;

  String? _error;
  String _status = '';
  bool _htmlLoaded = false;
  bool _bridgeReady = false;
  bool _started = false;
  bool _triedStagedHtml = false;
  bool _renderedNotified = false;
  double _zoom = 1.0;

  String? _chunkSource;
  String? _mediaDir;
  String? _packagePath;
  int _slideCount = 0;
  int _shown = 0;
  int _want = 0;
  int? _dragSlide;
  int? _loadingIndex;
  bool _running = false;
  bool _disposed = false;
  bool _openStarted = false;
  bool _openFailed = false;
  bool _emptyDeck = false;
  bool _hasShownAny = false;
  Completer<void>? _renderDone;

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
            if (url.contains('about:blank') || url.isEmpty && _chunkCount == 0) {
              _log.w(
                'Ignored main-frame error before viewer html: '
                '${error.description} $url',
              );
              return;
            }
            if (_chunkCount == 0) {
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
            _onViewerReady();
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

      if (widget.kind == OfficeVisualKind.presentation) {
        await _preparePresentation();
        return;
      }

      final length = await File(widget.filePath).length();
      if (length <= 0) {
        throw Exception('File is empty: ${widget.filePath}');
      }
      if (length > _maxOfficeBytes) {
        _log.w(
          'DOCX is $length bytes; visual preview stops at $_maxOfficeBytes',
        );
        _fail('paged-word');
        return;
      }
      _chunkCount = (length + _chunkBytes - 1) ~/ _chunkBytes;

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
        'chunks=$_chunkCount',
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
    if (_started || _chunkCount == 0) return;
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
          'window.$pending = $_chunkCount;',
        );
        _log.d('OfficeVisualViewer queued $pending=$_chunkCount');
        return;
      }
      _started = true;
      await _controller.runJavaScript(
        'window.$starter($_chunkCount);',
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
          if (index < 0 || index >= _chunkCount || requestId.isEmpty) {
            _fail('Invalid document chunk request');
            return;
          }
          final chunk = jsonEncode(await _readChunk(index));
          await _controller.runJavaScript(
            'window.receiveDocChunk(${jsonEncode(requestId)}, $chunk);',
          );
          break;
        case 'bridgeReady':
          _bridgeReady = true;
          _onViewerReady();
          break;
        case 'status':
          if (widget.kind == OfficeVisualKind.presentation) break;
          final text = payload['message'] as String? ?? '';
          if (!mounted) return;
          setState(() => _status = text);
          break;
        case 'rendered':
        case 'slideFailed':
          _finishRender();
          final slideFailed =
              type == 'slideFailed' || payload['slideFailed'] == true;
          if (slideFailed) {
            // A 0×0 canvas is a miss for this slide. The note is already
            // in the page. Do not log RENDERED for it.
            widget.onRendered?.call();
          } else if (!_renderedNotified) {
            _renderedNotified = true;
            _log.i('OfficeVisualViewer RENDERED kind=${widget.kind}');
            widget.onRendered?.call();
          }
          if (mounted) setState(() => _status = '');
          break;
        case 'zoom':
          final z = (payload['zoom'] as num?)?.toDouble();
          if (z != null && mounted) {
            final next = z.clamp(_minZoom, _maxZoom);
            setState(() => _zoom = next);
            widget.onZoomChanged?.call(next);
          }
          break;
        case 'slideDrawLog':
          final reason = payload['message']?.toString() ?? '';
          if (reason.isNotEmpty) {
            _log.w('PPTX slide draw: $reason');
          }
          break;
        case 'error':
          _finishRender();
          final message =
              payload['message']?.toString() ?? 'Render failed';
          if (widget.kind == OfficeVisualKind.presentation && _hasShownAny) {
            unawaited(_showSlideNote());
            return;
          }
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
    if (!mounted || _disposed) return;
    setState(() {
      _error = message;
      _status = '';
    });
    // PPTX stays on this surface so a later slide can still be opened.
    // DOCX asks the parent for the structured fallback.
    if (widget.kind != OfficeVisualKind.presentation) {
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

  void _onViewerReady() {
    if (_disposed) return;
    if (widget.kind != OfficeVisualKind.presentation) {
      unawaited(_startRender());
      return;
    }
    if (!_bridgeReady || !_htmlLoaded || _openStarted) return;
    _openStarted = true;
    unawaited(_goToSlide(0));
  }

  Future<void> _preparePresentation() async {
    final header = await File(widget.filePath).openRead(0, 8).fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    final isZip = header.length >= 2 && header[0] == 0x50 && header[1] == 0x4B;
    if (!isZip) {
      _fail('This file could not be opened.');
      return;
    }
    final length = await File(widget.filePath).length();
    if (length <= 0) {
      _fail('This file could not be opened.');
      return;
    }
    _triedStagedHtml = true;
    _log.i('PPTX paging open bytes=$length');
    final staging = await _stageViewerFiles();
    final sep = Platform.pathSeparator;
    final media = Directory('${staging.path}${sep}slide_media');
    await media.create(recursive: true);
    _mediaDir = media.path;
    _packagePath = '${staging.path}${sep}slide_package.zip';
    if (!mounted || _disposed) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _status = l10n?.viewerOpeningPresentation ?? '';
    });
    final htmlPath = '${staging.path}$sep$_htmlAssetName';
    await _controller.loadFile(htmlPath);
    _log.d('OfficeVisualViewer staged PPTX $htmlPath');
  }

  Future<void> _goToSlide(int index) async {
    if (_slideCount > 0) {
      index = index.clamp(0, _slideCount - 1);
    } else if (index < 0) {
      index = 0;
    }
    _want = index;
    if (_running) return;
    _running = true;
    try {
      while (!_disposed && mounted) {
        final target = _want;
        try {
          await _loadAndRender(target);
        } catch (e, st) {
          _log.e('PPTX slide load failed', error: e, stackTrace: st);
          if (_disposed || !mounted) return;
          if (!_hasShownAny) {
            _openFailed = true;
            _fail(e.toString());
            return;
          }
          await _showSlideNote();
          _shown = target;
        }
        if (_disposed || !mounted || _openFailed) return;
        if (_want == target) break;
      }
    } finally {
      _running = false;
      if (!_disposed && mounted && !_openFailed && _want != _shown) {
        unawaited(_goToSlide(_want));
      }
    }
  }

  Future<void> _loadAndRender(int index) async {
    if (_disposed || !mounted) return;
    final l10n = AppLocalizations.of(context);
    final failText = l10n?.viewerSlideDrawFailed ?? '';
    final opening = l10n?.viewerOpeningPresentation ?? '';
    setState(() {
      _loadingIndex = index;
      _status = opening;
    });
    try {
      await _controller.runJavaScript(
        'window.airdocsClearSlide && window.airdocsClearSlide();',
      );
    } catch (e, st) {
      _log.w('PPTX clear skipped: $e', error: e, stackTrace: st);
    }
    if (_disposed || !mounted) return;
    final mediaDir = _mediaDir;
    final packagePath = _packagePath;
    if (mediaDir == null || packagePath == null) {
      _openFailed = true;
      _fail('This file could not be opened.');
      return;
    }
    Map<String, dynamic> page;
    try {
      page = await _slides.readPptxSlide(
        filePath: widget.filePath,
        index: index,
        mediaDir: mediaDir,
        packagePath: packagePath,
      );
    } catch (e, st) {
      _log.e('PPTX slide read failed', error: e, stackTrace: st);
      if (_disposed || !mounted) return;
      if (!_hasShownAny) {
        _openFailed = true;
        _fail(e.toString());
        return;
      }
      await _showSlideNote();
      _shown = index;
      if (mounted) {
        setState(() {
          _loadingIndex = null;
          _status = '';
        });
      }
      return;
    }
    if (_disposed || !mounted) return;
    if (_want != index) return;
    final count = (page['slideCount'] as num?)?.toInt() ?? 0;
    final shown = (page['index'] as num?)?.toInt() ?? index;
    _slideCount = count;
    if (count <= 0) {
      _emptyDeck = true;
      _hasShownAny = true;
      _shown = 0;
      if (mounted) {
        setState(() {
          _loadingIndex = null;
          _status = '';
        });
      }
      return;
    }
    _hasShownAny = true;
    if (page['undrawable'] == true) {
      _log.w(
        'PPTX slide undrawable index=$shown reason=${page['reason'] ?? ''}',
      );
      await _showSlideNote();
      _shown = shown;
      if (mounted) {
        setState(() {
          _loadingIndex = null;
          _status = '';
          _slideCount = count;
          _shown = shown;
        });
      }
      return;
    }
    final media = page['media'];
    final map = <String, String>{};
    if (media is List) {
      for (final item in media) {
        if (item is! Map) continue;
        final zipPath = item['zipPath']?.toString() ?? '';
        final fileName = item['file']?.toString() ?? '';
        if (zipPath.isEmpty ||
            fileName.isEmpty ||
            fileName.contains('..') ||
            fileName.contains('/') ||
            fileName.contains('\\')) {
          continue;
        }
        map[zipPath] = 'slide_media/$fileName';
      }
    }
    final package = File(packagePath);
    final length = await package.length();
    if (_disposed || !mounted || _want != index) return;
    if (length <= 0 || length > 24 * 1024 * 1024) {
      _log.w('PPTX slide package unusable bytes=$length');
      await _showSlideNote();
      _shown = shown;
      if (mounted) {
        setState(() {
          _loadingIndex = null;
          _status = '';
          _slideCount = count;
          _shown = shown;
        });
      }
      return;
    }
    _chunkSource = packagePath;
    _chunkCount = (length + _chunkBytes - 1) ~/ _chunkBytes;
    final done = Completer<void>();
    _renderDone = done;
    try {
      await _controller.runJavaScript(
        'window.__airdocsPaging = true;'
        'window.__airdocsSlideFailText = ${jsonEncode(failText)};'
        'window.airdocsSetMedia(${jsonEncode(map)});'
        'window.startOfflinePptx($_chunkCount);',
      );
      await done.future.timeout(const Duration(seconds: 40));
    } on TimeoutException {
      _log.w('PPTX slide render timed out');
      try {
        await _controller.runJavaScript(
          'window.airdocsClearSlide && window.airdocsClearSlide();',
        );
      } catch (e, st) {
        _log.w('PPTX cancel skipped: $e', error: e, stackTrace: st);
      }
      if (_disposed || !mounted || _want != index) return;
      await _showSlideNote();
    } catch (e, st) {
      _log.e('PPTX slide render failed', error: e, stackTrace: st);
      if (_disposed || !mounted) return;
      await _showSlideNote();
    } finally {
      _finishRender();
    }
    if (_disposed || !mounted || _want != index) return;
    setState(() {
      _shown = shown;
      _slideCount = count;
      _loadingIndex = null;
      _status = '';
      _emptyDeck = false;
    });
  }

  Future<void> _showSlideNote() async {
    if (_disposed || !mounted) return;
    final text = AppLocalizations.of(context)?.viewerSlideDrawFailed ?? '';
    final done = Completer<void>();
    _renderDone = done;
    try {
      await _controller.runJavaScript(
        'window.airdocsShowSlideNote(${jsonEncode(text)});',
      );
      await done.future.timeout(const Duration(seconds: 5));
    } catch (e, st) {
      _log.w('PPTX slide note failed: $e', error: e, stackTrace: st);
    } finally {
      _finishRender();
    }
  }

  void _finishRender() {
    final done = _renderDone;
    if (done != null && !done.isCompleted) done.complete();
    _renderDone = null;
  }

  Future<String> _readChunk(int index) async {
    final start = index * _chunkBytes;
    final file = await File(_chunkSource ?? widget.filePath).open();
    try {
      await file.setPosition(start);
      final builder = BytesBuilder(copy: false);
      var remaining = _chunkBytes;
      while (remaining > 0) {
        final data = await file.read(remaining);
        if (data.isEmpty) break;
        builder.add(data);
        remaining -= data.length;
      }
      return base64Encode(builder.takeBytes());
    } finally {
      await file.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _finishRender();
    unawaited(_releaseWebView());
    super.dispose();
  }

  Future<void> _releaseWebView() async {
    try {
      await _controller.loadHtmlString('<!doctype html><html><body></body></html>');
    } catch (e) {
      _log.d('WebView release skipped: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.backgroundColor ?? const Color(0xFFF5F5F5);
    if (_error != null) {
      final l10n = AppLocalizations.of(context)!;
      return ColoredBox(
        color: bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              viewerFailureMessage(l10n, _error),
              textAlign: TextAlign.center,
              style: widget.kind == OfficeVisualKind.presentation
                  ? const TextStyle(color: Colors.white)
                  : null,
            ),
          ),
        ),
      );
    }

    final l10n = AppLocalizations.of(context)!;
    final viewer = Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        if (_emptyDeck)
          Positioned.fill(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  l10n.viewerNoSlides,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
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
                      _status,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    if (widget.kind != OfficeVisualKind.presentation || _slideCount <= 0) {
      return ColoredBox(color: bg, child: viewer);
    }
    return ColoredBox(
      color: bg,
      child: Column(
        children: [
          Expanded(child: viewer),
          _buildSlideBar(context, l10n),
        ],
      ),
    );
  }

  Widget _buildSlideBar(BuildContext context, AppLocalizations l10n) {
    final count = _slideCount;
    final raw = _dragSlide ?? _loadingIndex ?? _shown;
    final index = raw.clamp(0, count - 1);
    return Material(
      color: const Color(0xFF1C1C1C),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: l10n.viewerPreviousSlide,
                onPressed: index > 0 ? () => _goToSlide(index - 1) : null,
                icon: const Icon(Icons.chevron_left, color: Colors.white),
              ),
              Expanded(
                child: count <= 1
                    ? Text(
                        l10n.viewerSlidePosition(index + 1, count),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            l10n.viewerSlidePosition(index + 1, count),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: Colors.white,
                              inactiveTrackColor: Colors.white24,
                              thumbColor: Colors.white,
                              overlayColor: Colors.white24,
                            ),
                            child: Slider(
                              value: index.toDouble(),
                              min: 0,
                              max: (count - 1).toDouble(),
                              onChanged: (v) =>
                                  setState(() => _dragSlide = v.round()),
                              onChangeEnd: (v) {
                                setState(() => _dragSlide = null);
                                _goToSlide(v.round());
                              },
                            ),
                          ),
                        ],
                      ),
              ),
              IconButton(
                tooltip: l10n.viewerNextSlide,
                onPressed:
                    index < count - 1 ? () => _goToSlide(index + 1) : null,
                icon: const Icon(Icons.chevron_right, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

