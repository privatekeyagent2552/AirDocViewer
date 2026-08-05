import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:go_router/go_router.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'package:air_docs_viewer/features/viewer/data/providers/repository_providers.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/text_document_viewer.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/office_visual_viewer.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/rich_structured_document_viewer.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/modern_pdf_viewer.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/media_viewer.dart';
import 'package:video_player/video_player.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/document_viewer_factory.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/image_viewer.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/viewer_zoom_toolbar.dart';
import 'package:air_docs_viewer/features/viewer/presentation/providers/document_viewer_notifier.dart';
import 'package:air_docs_viewer/features/home/presentation/widgets/home_drawer.dart';
import 'package:air_docs_viewer/features/home/presentation/providers/thumbnail_provider.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/settings_providers.dart';
import 'package:air_docs_viewer/core/services/thumbnail_generation_service.dart';

class ViewerScreen extends ConsumerStatefulWidget {
  final String filePath;
  final String fileName;

  const ViewerScreen({
    required this.filePath,
    required this.fileName,
    super.key,
  });

  @override
  ConsumerState<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends ConsumerState<ViewerScreen>
    with TickerProviderStateMixin {
  static final _log = Logger();
  static const int _readingWordsPerMinute = 200;
  static const double _kSidebarBottomOffset = 88;
  static const double _kSidebarRadius = 24.0;
  static const IconData _chevronLeftNoMirror = IconData(
    0xe15e,
    fontFamily: 'MaterialIcons',
  );
  static const IconData _chevronRightNoMirror = IconData(
    0xe15f,
    fontFamily: 'MaterialIcons',
  );

  AppLocalizations get _l10n => AppLocalizations.of(context)!;

  bool _controlsVisible = true;
  bool _isFullscreen = false;
  bool _invertColors = false;
  bool _textMode = false;
  bool _bottomMenuExpanded = false;
  bool _sidebarOpen = false;
  int _currentPage = 1;
  int _totalPages = 0;
  int? _documentWordCount;
  int? _documentLineCount;
  double _sidebarDragOffset = 0.0;
  double _textFontSize = 18;
  bool _textWordWrap = true;
  bool _textFontIsMonoFont = false;
  bool _syntaxHighlightEnabled = true;
  bool _sessionStarted = false; // Prevent double session start
  RecentFilesMutator? _savedMutator; // Saved before dispose for safe access
  String? _sessionFilePath; // Saved before dispose for safe access
  late AnimationController _menuController;
  late AnimationController _sidebarController;
  // Sheet selection state for bottom panel display
  double _sheetZoom = 1.0;
  double _pdfZoom = 1.0;
  double _imageZoom = 1.0;
  String? _sheetCellRef;
  String _sheetCellValue = '';
  bool _mediaWasPlaying = false;
  double? _sliderDragValue;

  late AnimationController _topBarController;
  late AnimationController _bottomPanelController;
  late GlobalKey<State<ModernPdfViewer>> _pdfViewerKey;
  late GlobalKey<ImageViewerState> _imageViewerKey;
  late GlobalKey<State<TextDocumentViewer>> _textViewerKey;
  late GlobalKey<RichStructuredDocumentViewerState> _structuredViewerKey;
  late GlobalKey<MediaViewerState> _mediaViewerKey;
  late GlobalKey _sheetViewerKey;
  static const double _kDragCloseThreshold = 100.0;

  /// Path of a document whose rich WebView render failed; falls back to structured/text.
  String? _richFailedForPath;

  bool _isPdfDocument() {
    final ext = SupportedFormats.extensionOf(widget.filePath) ??
        SupportedFormats.extensionOf(widget.fileName) ??
        '';
    return SupportedFormats.viewerKindOf(ext) == ViewerKind.pdf;
  }

  bool _isSpreadsheet() {
    final ext = SupportedFormats.extensionOf(widget.filePath) ??
        SupportedFormats.extensionOf(widget.fileName) ??
        '';
    return SupportedFormats.isSpreadsheet(ext);
  }

  /// Must match the actual floating top bar content height (52).
  static const double _kTopBarContentHeight = 52.0;

  /// Safe top inset that always clears the status bar / camera cutout, even in
  /// immersive mode where the reported system inset can collapse to 0.
  double _safeTopInset(BuildContext context) {
    final mq = MediaQuery.of(context);
    final inset = math.max(mq.viewPadding.top, mq.padding.top);
    // Guarantee clearance for notches/punch-holes when immersive hides the bar.
    return math.max(inset, 28.0);
  }

  double _topOverlayHeight(BuildContext context) =>
      _safeTopInset(context) + _kTopBarContentHeight;

  double _bottomOverlayHeight(BuildContext context) {
    if (!_controlsVisible) return 0.0;
    final navInset = MediaQuery.viewPaddingOf(context).bottom;
    final panel = _isSpreadsheet() ? 96.0 : 56.0;
    return panel + navInset;
  }

  EdgeInsets _contentOverlayPadding(BuildContext context) {
    return EdgeInsets.only(
      top: _controlsVisible ? _topOverlayHeight(context) : 0.0,
      bottom: _bottomPanelController.value > 0.3
          ? _bottomOverlayHeight(context)
          : 0.0,
    );
  }

  Future<void> _setFullscreen(bool enabled) async {
    _isFullscreen = enabled;
    if (enabled) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _toggleFullscreen() async {
    // Only for spreadsheets
    if (!_isSpreadsheet()) return;

    final willShowControls = !_controlsVisible;
    setState(() {
      _controlsVisible = willShowControls;
      _isFullscreen = !willShowControls;
      if (!willShowControls) {
        _sidebarOpen = false;
        _bottomMenuExpanded = false;
      }
    });

    if (willShowControls) {
      _topBarController.forward();
      _bottomPanelController.forward();
      await _setFullscreen(false);
    } else {
      _topBarController.reverse();
      _bottomPanelController.reverse();
      _sidebarController.reverse();
      _menuController.reverse();
      await _setFullscreen(true);
    }
  }

  /// Formats whose native representation is plain/code text, or office
  /// formats that only have text/structured fallbacks (not DOCX/PPTX WebView).
  bool _isTextLikeFormat(String format) {
    final ext = format.toLowerCase();
    final kind = SupportedFormats.viewerKindOf(ext);
    return kind == ViewerKind.text ||
        (kind == ViewerKind.structured &&
            !_isRichWebActive(format));
  }

  bool _isRichWebActive(String format) {
    final ext = format.toLowerCase();
    return SupportedFormats.isRichWeb(ext) &&
        _richFailedForPath != widget.filePath &&
        !(ref.read(documentViewerProvider).usingFallback);
  }

  bool _isTextDocument() {
    final format =
        ref.read(documentViewerProvider).document?.format.toUpperCase() ?? '';
    return _isTextLikeFormat(format);
  }

  bool _isStructuredRichDocument() {
    final doc = ref.read(documentViewerProvider).document;
    if (doc == null || !doc.hasRichDocument) return false;
    final format = doc.format.toUpperCase();
    if (_isRichWebActive(format)) return false;
    final kind = SupportedFormats.viewerKindOf(format.toLowerCase());
    return kind == ViewerKind.structured ||
        kind == ViewerKind.richWeb ||
        kind == ViewerKind.text;
  }

  bool _canOpenSidebar() {
    if (!_controlsVisible) return false;
    if (_isPdfDocument()) {
      return _pdfViewerKey.currentState != null;
    }
    if (_isStructuredRichDocument()) {
      return _structuredViewerKey.currentState != null;
    }
    if (_isTextDocument()) {
      return _textViewerKey.currentState != null;
    }
    // Enable for spreadsheets — they have search in the factory-created viewer
    if (_isSpreadsheet()) {
      return true;
    }
    return false;
  }

  Widget? _resolveSidebarContent(BuildContext context) {
    if (_isPdfDocument()) {
      final viewerState = _pdfViewerKey.currentState as dynamic;
      return viewerState?.buildDrawerContent(context) as Widget?;
    }
    if (_isStructuredRichDocument()) {
      return _structuredViewerKey.currentState?.buildDrawerContent(context);
    }
    if (_isTextDocument()) {
      final viewerState = _textViewerKey.currentState as dynamic;
      return viewerState?.buildDrawerContent(context) as Widget?;
    }
    // Show simple search placeholder for spreadsheets
    if (_isSpreadsheet()) {
      return _buildSpreadsheetSearchPlaceholder(context);
    }
    return null;
  }

  /// Simple search placeholder for spreadsheet - minimal height for landscape
  Widget _buildSpreadsheetSearchPlaceholder(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Minimal thin search field
          TextField(
            autofocus: false,
            style: Theme.of(context).textTheme.bodySmall,
            decoration: InputDecoration(
              hintText: l10n.viewerFindHint,
              prefixIcon: const Icon(Icons.search, size: 16),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
            ),
            onChanged: (query) {
              if (query.isNotEmpty) {
                _performSheetSearch(query);
              }
            },
          ),
          const SizedBox(height: 4),
          // Scrollable results
          Expanded(
            child: _sheetSearchResults.isEmpty
                ? Center(
                    child: Text(
                      l10n.viewerTypeToFind,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    itemCount: _sheetSearchResults.length.clamp(0, 30),
                    itemBuilder: (ctx, i) {
                      final r = _sheetSearchResults[i];
                      return InkWell(
                        onTap: () {
                          _jumpToSheetCell(r['row'] as int, r['col'] as int);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                  '${_colLabel(r['col'] as int)}${(r['row'] as int) + 1}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary)),
                              const SizedBox(width: 4),
                              Expanded(
                                  child: Text(r['value'] as String,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall)),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _sheetSearchResults = [];

  void _performSheetSearch(String query) async {
    if (query.isEmpty) {
      setState(() => _sheetSearchResults.clear());
      return;
    }
    final doc = ref.read(documentViewerProvider).document;
    if (doc == null) return;

    final results = <Map<String, dynamic>>[];
    final q = query.toLowerCase();
    for (var si = 0; si < doc.sheets.length; si++) {
      final sheet = doc.sheets[si];
      for (var ri = 0; ri < sheet.rows.length; ri++) {
        for (var ci = 0; ci < sheet.rows[ri].length; ci++) {
          final cell = sheet.rows[ri][ci];
          if (cell.toLowerCase().contains(q)) {
            results.add({'row': ri, 'col': ci, 'value': cell});
            if (results.length >= 30) break;
          }
        }
        if (results.length >= 30) break;
      }
      if (results.length >= 30) break;
    }
    setState(() => _sheetSearchResults = results);
  }

  void _jumpToSheetCell(int row, int col) {
    final viewer = _sheetViewerKey.currentState as dynamic;
    if (viewer != null && viewer.scrollToCell != null) {
      viewer.scrollToCell(row, col);
    }
    if (_sidebarOpen) _closeSidebar();
    final l10n = _l10n;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.viewerCellCopied('${_colLabel(col)}${row + 1}')),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  String _colLabel(int col) => String.fromCharCode(65 + (col % 26));

  void _toggleControls() {
    final willBeVisible = !_controlsVisible;
    setState(() {
      _controlsVisible = willBeVisible;
      _isFullscreen = false;
      if (!willBeVisible) {
        _sidebarOpen = false;
        _bottomMenuExpanded = false;
      }
    });
    // Animate top/bottom together
    if (willBeVisible) {
      _topBarController.forward();
      _bottomPanelController.forward();
    } else {
      _topBarController.reverse();
      _bottomPanelController.reverse();
      _sidebarController.reverse();
      _menuController.reverse();
    }
  }

  void _toggleBottomMenu() {
    setState(() {
      _bottomMenuExpanded = !_bottomMenuExpanded;
    });
    if (_bottomMenuExpanded) {
      _menuController.forward();
    } else {
      _menuController.reverse();
    }
  }

  void _toggleSidebar() {
    if (!_canOpenSidebar()) {
      _log.d('Sidebar toggle ignored: no sidebar content available yet.');
      return;
    }
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.toggleSidebar();
    }
    setState(() {
      _sidebarOpen = !_sidebarOpen;
    });
    if (_sidebarOpen) {
      _sidebarController.forward();
    } else {
      _sidebarController.reverse();
    }
  }

  void _onSearchHighlight() {
    if (!_sidebarOpen) return;
    if (_isPdfDocument()) {
      final viewerState = _pdfViewerKey.currentState as dynamic;
      final isSidebarOpen = viewerState?.showSidebar as bool? ?? false;
      if (isSidebarOpen) {
        viewerState?.toggleSidebar();
      }
    }
    setState(() => _sidebarOpen = false);
    _sidebarController.reverse();
    Future.delayed(const Duration(milliseconds: 1800), () {
      if (mounted) {
        if (_isPdfDocument()) {
          final viewerState = _pdfViewerKey.currentState as dynamic;
          final isSidebarOpen = viewerState?.showSidebar as bool? ?? false;
          if (!isSidebarOpen) {
            viewerState?.toggleSidebar();
          }
        }
        setState(() => _sidebarOpen = true);
        _sidebarController.forward();
      }
    });
  }

  void _goToFirstPage() {
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.goToFirstPage();
    }
  }

  void _goToPreviousPage() {
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.goToPreviousPage();
    }
  }

  void _goToNextPage() {
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.goToNextPage();
    }
  }

  void _closeSidebar() {
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.toggleSidebar();
    }
    setState(() => _sidebarOpen = false);
    _sidebarController.reverse();
  }

  void _handleSidebarDragUpdate(DragUpdateDetails details) {
    setState(() {
      final isRTL = Directionality.of(context) == TextDirection.rtl;
      // Normalize: negative offset always means "closing" direction.
      final delta = isRTL ? -details.delta.dx : details.delta.dx;
      _sidebarDragOffset += delta;
      _sidebarDragOffset = _sidebarDragOffset.clamp(-500.0, 0.0);
    });
  }

  void _handleSidebarDragEnd(DragEndDetails details) {
    if (_sidebarDragOffset < -_kDragCloseThreshold) {
      setState(() => _sidebarOpen = false);
      _sidebarController.reverse();
      Future.delayed(const Duration(milliseconds: 260), () {
        if (mounted && !_sidebarOpen) {
          setState(() => _sidebarDragOffset = 0.0);
        }
      });
    } else {
      setState(() => _sidebarDragOffset = 0.0);
    }
  }

  void _goToLastPage() {
    if (_isPdfDocument()) {
      (_pdfViewerKey.currentState as dynamic)?.goToLastPage();
    }
  }

  void _showGoToPageDialog() {
    final l10n = _l10n;
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.viewerGoToPage),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: l10n.viewerGoToPageHint(_totalPages),
            border: const OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () {
              final pageNum = int.tryParse(textController.text);
              if (pageNum != null && pageNum >= 1 && pageNum <= _totalPages) {
                if (_isPdfDocument()) {
                  (_pdfViewerKey.currentState as dynamic)?.goToPage(pageNum);
                }
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n.viewerInvalidPage(_totalPages)),
                  ),
                );
              }
            },
            child: Text(l10n.viewerGo),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _pdfViewerKey = GlobalKey<State<ModernPdfViewer>>();
    _imageViewerKey = GlobalKey<ImageViewerState>();
    _textViewerKey = GlobalKey<State<TextDocumentViewer>>();
    _structuredViewerKey = GlobalKey<RichStructuredDocumentViewerState>();
    _mediaViewerKey = GlobalKey<MediaViewerState>();
    _sheetViewerKey = GlobalKey();
    _menuController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _sidebarController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _topBarController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );
    _bottomPanelController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );

    // Set initial values NOW in constructor (before first build)
    // This ensures controls visible on first frame
    _topBarController.value = 1.0;
    _bottomPanelController.value = 1.0;
    _sidebarController.value = 0.0;

    // Start in immersive mode by default for better UX
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // Start document load immediately (don't wait for first frame).
    Future.microtask(() async {
      if (!mounted) return;
      final docState = ref.read(documentViewerProvider);
      final loadedPath = docState.document?.sourceFilePath;
      final needsLoad = !docState.isLoading &&
          (docState.document == null ||
              loadedPath == null ||
              loadedPath != widget.filePath ||
              docState.hasError);
      _log.d(
        'initState: loading=${docState.isLoading} hasDoc=${docState.document != null} '
        'hasError=${docState.hasError} needsLoad=$needsLoad path=${widget.filePath}',
      );

      if (needsLoad) {
        _log.d('Loading document: ${widget.fileName}');
        unawaited(
          ref
              .read(documentViewerProvider.notifier)
              .initializeAndLoad(widget.filePath, widget.fileName)
              .then((_) {
            if (!mounted || _sessionStarted) return;
            _sessionStarted = true;
            _savedMutator = ref.read(recentFilesMutatorProvider);
            _sessionFilePath = widget.filePath;
            _savedMutator!.startViewingSession(widget.filePath);
            _log.d('Time tracking started: ${widget.filePath}');
            if (isMediaFormat(widget.filePath)) {
              setState(() {});
            }
          }),
        );
      } else if (!_sessionStarted) {
        _log.d('Document already loaded, starting session...');
        _sessionStarted = true;
        _savedMutator = ref.read(recentFilesMutatorProvider);
        _sessionFilePath = widget.filePath;
        _savedMutator!.startViewingSession(widget.filePath);
      }

      try {
        await ref
            .read(recentFilesMutatorProvider)
            .updateDateOpened(widget.filePath);
      } catch (e, st) {
        _log.w('updateDateOpened failed: $e', error: e, stackTrace: st);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update system UI overlay when theme changes
    _updateSystemUIOverlay();
  }

  void _updateSystemUIOverlay() {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
  }

  @override
  void dispose() {
    _log.d('dispose: ending session for ');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    // End viewing session using saved reference (ref is unsafe in dispose)
    if (_savedMutator != null && _sessionFilePath != null) {
      _savedMutator!.endViewingSession(_sessionFilePath!);
      _log.d('Session end triggered via saved ref');
    } else {
      _log.w('No saved mutator - session time NOT saved');
    }
    _menuController.dispose();
    _sidebarController.dispose();
    _topBarController.dispose();
    _bottomPanelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docState = ref.watch(documentViewerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context)!;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          context.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Stack(
          children: [
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final pathExt = SupportedFormats.extensionOf(widget.filePath) ??
                      SupportedFormats.extensionOf(widget.fileName) ??
                      '';
                  final fromDoc =
                      docState.document?.format.toUpperCase() ?? '';
                  final richWeb =
                      SupportedFormats.isRichWeb(pathExt) ||
                      SupportedFormats.isRichWeb(fromDoc.toLowerCase());
                  final useVisual = richWeb &&
                      !docState.hasError &&
                      !docState.usingFallback &&
                      _richFailedForPath != widget.filePath;

                  if (useVisual) {
                    final kind = (fromDoc == 'DOCX' || pathExt == 'docx')
                        ? OfficeVisualKind.word
                        : OfficeVisualKind.presentation;
                    return Padding(
                      padding: _contentOverlayPadding(context),
                      child: OfficeVisualViewer(
                        key: ValueKey('office_visual_${widget.filePath}'),
                        filePath: widget.filePath,
                        kind: kind,
                        backgroundColor: const Color(0xFFF5F5F5),
                        onRendered: () {
                          ref.read(documentViewerProvider.notifier).markReady();
                        },
                        onError: (message) {
                          _log.w(
                            'Office visual failed: $message — loading fallback',
                          );
                          if (!mounted) return;
                          setState(() => _richFailedForPath = widget.filePath);
                          unawaited(
                            ref
                                .read(documentViewerProvider.notifier)
                                .loadStructuredFallback(),
                          );
                        },
                      ),
                    );
                  }

                  if (docState.isLoading ||
                      docState.phase == ViewerPhase.preparing) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (docState.parsingStatus != null) ...[
                            const SizedBox(height: 16),
                            Text(docState.parsingStatus!),
                          ],
                        ],
                      ),
                    );
                  }
                  if (docState.hasError) {
                    return _buildErrorState(context, ref, docState);
                  }
                  if (docState.document != null) {
                    return Padding(
                      padding: _contentOverlayPadding(context),
                      child: _buildContentViewer(
                        document: docState.document!,
                      ),
                    );
                  }
                  return Center(child: Text(l10n.viewerNoContent));
                },
              ),
            ),

            // Scrim overlay with dimming and tap/swipe-to-close
            Positioned.fill(
              child: IgnorePointer(
                ignoring: !_sidebarOpen || !_controlsVisible,
                child: AnimatedBuilder(
                  animation: _sidebarController,
                  builder: (context, child) {
                    return Opacity(
                      opacity: _sidebarController.value,
                      child: GestureDetector(
                        onTap: _closeSidebar,
                        onHorizontalDragUpdate: _handleSidebarDragUpdate,
                        onHorizontalDragEnd: _handleSidebarDragEnd,
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.45),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),

            // Sidebar with slide-in animation and drag support
            Positioned(
              top: _topOverlayHeight(context),
              bottom: _kSidebarBottomOffset - _kSidebarRadius,
              left: Directionality.of(context) == TextDirection.rtl ? null : 0,
              right: Directionality.of(context) == TextDirection.rtl ? 0 : null,
              child: AnimatedBuilder(
                animation: _sidebarController,
                builder: (context, child) {
                  final isRTL = Directionality.of(context) == TextDirection.rtl;
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: isRTL
                          ? const Offset(1.0, 0.0)
                          : const Offset(-1.0, 0.0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _sidebarController,
                      curve: Curves.easeOutCubic,
                    )),
                    child: IgnorePointer(
                      ignoring: !_sidebarOpen,
                      child: _controlsVisible
                          ? _buildSidebarDrawer(context, isDark)
                          : const SizedBox.shrink(),
                    ),
                  );
                },
              ),
            ),

            // Floating back button — Positioned must be the Stack child.
            Positioned(
              top: _safeTopInset(context) + 8,
              left: Directionality.of(context) == TextDirection.rtl ? null : 8,
              right: Directionality.of(context) == TextDirection.rtl ? 8 : null,
              child: AnimatedBuilder(
                animation: _topBarController,
                builder: (context, child) {
                  final opacity =
                      (1.0 - _topBarController.value).clamp(0.0, 1.0);
                  return IgnorePointer(
                    ignoring: opacity < 0.05,
                    child: Opacity(
                      opacity: opacity,
                      child: child,
                    ),
                  );
                },
                child: Material(
                  color: Theme.of(context)
                      .colorScheme
                      .surface
                      .withValues(alpha: 0.92),
                  shape: const CircleBorder(),
                  elevation: 3,
                  child: IconButton(
                    icon: Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? _chevronRightNoMirror
                          : _chevronLeftNoMirror,
                    ),
                    tooltip: _l10n.back,
                    iconSize: 24,
                    color: Theme.of(context).colorScheme.onSurface,
                    onPressed: () => context.pop(),
                  ),
                ),
              ),
            ),

            // Top bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedBuilder(
                animation: _topBarController,
                builder: (context, child) {
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -2.0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _topBarController,
                      curve: Curves.easeOutCubic,
                    )),
                    child: child,
                  );
                },
                child: _buildFloatingTopBar(context, isDark),
              ),
            ),

            // Bottom panel
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedBuilder(
                animation: _bottomPanelController,
                builder: (context, child) {
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1.0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                      parent: _bottomPanelController,
                      curve: Curves.easeOutCubic,
                    )),
                    child: child,
                  );
                },
                child: _buildFloatingBottomPanel(context, isDark),
              ),
            ),

            // Fullscreen exit button - visible only in true fullscreen
            if (_isFullscreen)
              Positioned(
                bottom: 16,
                right: 16,
                child: FloatingActionButton.small(
                  onPressed: _toggleControls,
                  child: const Icon(Icons.fullscreen_exit, size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String? _getHighlightLanguage(String format) =>
      _languageForFormat(format);

  static String? _languageForFormat(String format) {
    switch (format) {
      case 'JAVA':
        return 'java';
      case 'PY':
        return 'python';
      case 'SH':
        return 'bash';
      case 'HTML':
        return 'xml';
      case 'MD':
        return 'markdown';
      case 'JSON':
        return 'json';
      case 'XML':
        return 'xml';
      case 'FADREC':
        return 'json';
      default:
        return null;
    }
  }

  Widget _buildContentViewer({required ParsedDocumentEntity document}) {
    final format = document.format.toUpperCase();
    _log.d(
      'Building viewer for format=$format rich=${document.hasRichDocument} '
      'fidelity=${document.fidelityLevel.name} warnings=${document.parseWarnings.length}',
    );

    // For PDFs, use ModernPdfViewer with GlobalKey to access navigation
    if (format == 'PDF') {
      return ModernPdfViewer(
        key: _pdfViewerKey,
        filePath: widget.filePath,
        fileName: widget.fileName,
        invertColors: _invertColors,
        textMode: _textMode,
        onTap: _toggleControls,
        onInvertToggle: () {
          setState(() => _invertColors = !_invertColors);
        },
        onTextModeToggle: () {
          setState(() => _textMode = !_textMode);
        },
        onPageChanged: (current, total) {
          if (total > 0) {
            setState(() {
              _currentPage = current;
              _totalPages = total;
            });
          }
        },
        onSearchHighlight: _onSearchHighlight,
        initialWordCount: document.wordCount,
        initialLineCount: document.lineCount,
        onTextStatsChanged: (wordCount, lineCount) {
          if (!mounted) return;
          setState(() {
            _documentWordCount = wordCount;
            _documentLineCount = lineCount;
          });
          _cachePdfTextStats(document, wordCount, lineCount);
        },
        onZoomChanged: (zoom) {
          if (!mounted) return;
          setState(() => _pdfZoom = zoom);
        },
      );
    }

    // DOCX / PPTX: pure-Flutter visual when not in fallback mode.
    final formatExt = format.toLowerCase();
    if (SupportedFormats.isRichWeb(formatExt) &&
        !ref.read(documentViewerProvider).usingFallback &&
        _richFailedForPath != widget.filePath) {
      return OfficeVisualViewer(
        key: ValueKey('office_visual_${widget.filePath}'),
        filePath: widget.filePath,
        kind: format == 'DOCX'
            ? OfficeVisualKind.word
            : OfficeVisualKind.presentation,
        backgroundColor: const Color(0xFFF5F5F5),
        onRendered: () {
          ref.read(documentViewerProvider.notifier).markReady();
        },
        onError: (message) {
          _log.w('Office visual failed for $format: $message — loading fallback');
          if (!mounted) return;
          setState(() => _richFailedForPath = widget.filePath);
          unawaited(
            ref.read(documentViewerProvider.notifier).loadStructuredFallback(),
          );
        },
      );
    }

    // Structured Flutter viewer for office/ebook blocks (styles, lists, tables).
    final kind = SupportedFormats.viewerKindOf(formatExt);
    if (document.hasRichDocument &&
        (kind == ViewerKind.structured ||
            kind == ViewerKind.richWeb ||
            kind == ViewerKind.text)) {
      return RichStructuredDocumentViewer(
        key: _structuredViewerKey,
        document: document,
        onTap: _toggleControls,
        onSearchHighlight: _onSearchHighlight,
        fontSize: _textFontSize,
      );
    }

    // Plain/code documents — and office formats without structured blocks.
    if (_isTextLikeFormat(format) ||
        kind == ViewerKind.structured ||
        kind == ViewerKind.text ||
        kind == ViewerKind.richWeb) {
      final text = document.searchableText;
      if (text.isEmpty && document.slides.isNotEmpty) {
        final slideText = document.slides
            .map((s) => '[Slide ${s.slideNumber}]\n${s.text}')
            .join('\n\n');
        return TextDocumentViewer(
          key: _textViewerKey,
          textContent: slideText,
          onTap: _toggleControls,
          onSearchHighlight: _onSearchHighlight,
          fontSize: _textFontSize,
          wordWrap: _textWordWrap,
          useMonoFont: _textFontIsMonoFont,
          language: _syntaxHighlightEnabled ? _languageForFormat(format) : null,
        );
      }
      return TextDocumentViewer(
        key: _textViewerKey,
        textContent: text.isEmpty ? 'No readable content found in this file.' : text,
        onTap: _toggleControls,
        onSearchHighlight: _onSearchHighlight,
        fontSize: _textFontSize,
        wordWrap: _textWordWrap,
        useMonoFont: _textFontIsMonoFont,
        language: _syntaxHighlightEnabled ? _languageForFormat(format) : null,
      );
    }

    // For audio/video media files, use MediaViewer with playback controls
    if (isMediaFormat(widget.filePath) || kind == ViewerKind.media) {
      return MediaViewer(
        key: _mediaViewerKey,
        filePath: widget.filePath,
        fileName: widget.fileName,
        onTap: _toggleControls,
      );
    }

    if (kind == ViewerKind.image || SupportedFormats.isImage(formatExt)) {
      return ImageViewer(
        key: _imageViewerKey,
        filePath: widget.filePath,
        onTap: _toggleControls,
        onZoomChanged: (zoom) {
          if (!mounted) return;
          setState(() => _imageZoom = zoom);
        },
      );
    }

    // Spreadsheets: same as PDF — zoom only in the bottom panel (no floating overlay).
    if (kind == ViewerKind.spreadsheet ||
        document.isSpreadsheet ||
        _isSpreadsheet()) {
      return DocumentViewerFactory.createViewer(
        document: document,
        filePath: widget.filePath,
        onTap: _toggleControls,
        onSheetSelectionChanged: (cellRef, value) {
          setState(() {
            _sheetCellRef = cellRef;
            _sheetCellValue = value;
          });
        },
        sheetViewerKey: _sheetViewerKey,
        sheetZoom: _sheetZoom,
      );
    }

    // For other document types, use the factory
    return DocumentViewerFactory.createViewer(
      document: document,
      filePath: widget.filePath,
      invertColors: _invertColors,
      textMode: _textMode,
      onInvertToggle: () {
        setState(() => _invertColors = !_invertColors);
      },
      onTextModeToggle: () {
        setState(() => _textMode = !_textMode);
      },
      onSheetSelectionChanged: (cellRef, value) {
        setState(() {
          _sheetCellRef = cellRef;
          _sheetCellValue = value;
        });
      },
      sheetViewerKey: _sheetViewerKey,
      sheetZoom: _sheetZoom,
    );
  }

  Widget _buildFloatingTopBar(BuildContext context, bool isDark) {
    return GestureDetector(
      onTap: () {}, // Absorb taps to prevent triggering PDF tap
      child: Stack(
        children: [
          // Shadow below the top bar
          Positioned(
            bottom: -8,
            left: 0,
            right: 0,
            height: 8,
            child: Container(
              decoration: BoxDecoration(
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.3)
                        : Colors.black.withValues(alpha: 0.1),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
          // Main top bar with rounded bottom corners
          ClipRRect(
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.95)
                      : Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.92),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.2),
                      width: 1,
                    ),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(
                    top: _safeTopInset(context),
                  ),
                  child: SizedBox(
                    height: _kTopBarContentHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Row(
                        children: [
                          // Prominent, always-visible back button (leading).
                          Material(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.10),
                            shape: const CircleBorder(),
                            child: IconButton(
                              icon: Icon(
                                Directionality.of(context) == TextDirection.rtl
                                    ? _chevronRightNoMirror
                                    : _chevronLeftNoMirror,
                              ),
                              onPressed: () => context.pop(),
                              tooltip: _l10n.back,
                              iconSize: 26,
                              color: Theme.of(context).colorScheme.primary,
                              constraints: const BoxConstraints(
                                minWidth: 44,
                                minHeight: 44,
                              ),
                              padding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(width: 4),
                          // File name + reading stats fill the remaining space,
                          // so they can never overlap the back button.
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Text(
                                  widget.fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .labelLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                                _buildTimeToRead(context),
                              ],
                            ),
                          ),
                          // Trailing spacer to keep the title visually centered.
                          const SizedBox(width: 48),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTimeToRead(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final docState = ref.watch(documentViewerProvider);
    if (docState.document == null) {
      return const SizedBox.shrink();
    }

    final document = docState.document!;
    final textContent = document.searchableText;
    final hasEmbeddedText = textContent.isNotEmpty;
    final wordCount = hasEmbeddedText
        ? textContent.split(RegExp(r'\s+')).length
        : (document.wordCount ?? _documentWordCount);
    final lineCount = hasEmbeddedText
        ? textContent.split(RegExp(r'\r\n|\r|\n')).length
        : (document.lineCount ?? _documentLineCount);

    if (wordCount == null || lineCount == null || wordCount == 0) {
      return const SizedBox.shrink();
    }

    final readingMinutes =
        (wordCount / _readingWordsPerMinute).ceil().clamp(1, 99999);
    final hours = readingMinutes ~/ 60;
    final minutes = readingMinutes % 60;
    final readingTimeStr = readingMinutes >= 60
        ? l10n.viewerReadingTimeHoursMinutes(hours, minutes)
        : l10n.viewerReadingTimeMinutes(readingMinutes);

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '$readingTimeStr • ${l10n.viewerWordsOnly(wordCount)} • ${l10n.viewerLinesOnly(lineCount)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }

  Future<void> _cachePdfTextStats(
    ParsedDocumentEntity document,
    int wordCount,
    int lineCount,
  ) async {
    if (document.format.toUpperCase() != 'PDF') return;
    if (document.wordCount == wordCount && document.lineCount == lineCount) {
      return;
    }

    final cachedDocument = document.copyWith(
      wordCount: wordCount,
      lineCount: lineCount,
      parsedAt: DateTime.now(),
    );

    // Capture brightness before async gap
    final brightnessName =
        Theme.of(context).brightness == Brightness.dark ? 'dark' : 'light';
    try {
      final repository = ref.read(documentParsingRepositoryProvider);
      await repository.cacheParsing(widget.filePath, cachedDocument);

      final thumbnailBytes = await ThumbnailGenerationService.generateThumbnail(
        widget.filePath,
        widget.fileName,
        'pdf',
        cachedDocument: cachedDocument,
      );
      if (thumbnailBytes != null) {
        final hiveDatasource = ref.read(hiveDatasourceProvider);
        final recentFiles = await hiveDatasource.getRecentFiles();
        for (final file in recentFiles) {
          if (file.filePath == widget.filePath) {
            await hiveDatasource.saveThumbnail(file.id, thumbnailBytes,
                brightness: brightnessName);
            ref.invalidate(thumbnailProvider(file.id));
            break;
          }
        }
      }
    } catch (e, st) {
      _log.w('Failed to cache PDF text stats', error: e, stackTrace: st);
    }
  }

  Widget _buildIconButton(
    BuildContext context,
    IconData icon,
    VoidCallback? onTap,
  ) {
    return SizedBox(
      width: 42,
      height: 42,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Icon(
            icon,
            size: 22,
            color: onTap != null
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant
                    .withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }

  Widget _buildPageIndicator(BuildContext context) {
    return GestureDetector(
      onTap: _totalPages > 1 ? _showGoToPageDialog : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .primaryContainer
              .withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '$_currentPage/$_totalPages',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      ),
    );
  }

  Widget _buildTile(
      {required IconData icon,
      required String label,
      required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
        ),
      ),
    );
  }

  void _copyPdfText() async {
    final l10n = _l10n;
    final viewerState = _pdfViewerKey.currentState as dynamic;
    if (viewerState == null) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(ctx)!.viewerExtractingAllPages),
          ],
        ),
      ),
    );

    try {
      final extractMethod = viewerState.extractAllText;
      if (extractMethod == null) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.viewerTextExtractionUnavailable)),
          );
        }
        return;
      }

      final result = await extractMethod() as Map<String, dynamic>;
      if (mounted) {
        Navigator.pop(context);
      }

      final text = result['text'] as String;
      final wordCount = result['wordCount'] as int;
      final pageCount = result['pageCount'] as int;

      if (text.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.viewerNoPdfText)),
          );
        }
        return;
      }

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) {
            final dialogL10n = AppLocalizations.of(ctx)!;

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.copy_all,
                      size: 20, color: Theme.of(ctx).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(dialogL10n.viewerCopyAllTextTitle),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dialogL10n.viewerCopyAllTextConfirm(pageCount)),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.text_fields,
                            size: 16, color: Theme.of(ctx).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          dialogL10n.viewerWordsFound(wordCount),
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(dialogL10n.cancel),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(ClipboardData(text: text));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              l10n.viewerCopiedAllPages(wordCount, pageCount)),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(dialogL10n.copy),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.viewerErrorPrefix(e.toString()))),
        );
      }
    }
  }

  void _copyDocumentText() async {
    final l10n = _l10n;
    // For TXT/DOCX/DOC, copy all content
    final doc = ref.watch(documentViewerProvider);
    if (doc.document == null) return;

    final text = doc.document!.searchableText;
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.viewerNoTextAvailable)),
        );
      }
      return;
    }

    final wordCount = text.split(RegExp(r'\s+')).length;
    final lineCount = text.split('\n').length;

    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) {
          final dialogL10n = AppLocalizations.of(ctx)!;

          return AlertDialog(
            title: Row(
              children: [
                Icon(Icons.copy_all,
                    size: 20, color: Theme.of(ctx).colorScheme.primary),
                const SizedBox(width: 8),
                Text(dialogL10n.viewerCopyAllTextTitle),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(dialogL10n.viewerCopyDocumentText),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.text_fields,
                              size: 16,
                              color: Theme.of(ctx).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            dialogL10n.viewerWordsOnly(wordCount),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(Icons.format_list_numbered,
                              size: 16,
                              color: Theme.of(ctx).colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            dialogL10n.viewerLinesOnly(lineCount),
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(ctx).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(dialogL10n.cancel),
              ),
              FilledButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await Clipboard.setData(ClipboardData(text: text));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            l10n.viewerCopiedFromLines(wordCount, lineCount)),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.copy, size: 16),
                label: Text(dialogL10n.copy),
              ),
            ],
          );
        },
      );
    }
  }

  void _copyImageExtractedText() async {
    final l10n = _l10n;
    // For images, copy extracted text from OCR if available
    try {
      final hiveDatasource = ref.read(hiveDatasourceProvider);
      final recentFiles = await hiveDatasource.getRecentFiles();

      // Find the file matching current path
      dynamic file;
      for (final f in recentFiles) {
        if (f.filePath == widget.filePath) {
          file = f;
          break;
        }
      }

      if (file == null ||
          file.extractedText == null ||
          file.extractedText!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.viewerNoTextForImage)),
          );
        }
        return;
      }

      final text = file.extractedText!;
      final wordCount =
          text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
      final charCount = text.length;

      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) {
            final dialogL10n = AppLocalizations.of(ctx)!;

            return AlertDialog(
              title: Row(
                children: [
                  Icon(Icons.copy_all,
                      size: 20, color: Theme.of(ctx).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(dialogL10n.viewerCopyExtractedTitle),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dialogL10n.viewerCopyExtractedDesc),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.text_fields,
                                size: 16,
                                color: Theme.of(ctx).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              dialogL10n.viewerWordsOnly(wordCount),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Icon(Icons.format_list_numbered,
                                size: 16,
                                color: Theme.of(ctx).colorScheme.primary),
                            const SizedBox(width: 8),
                            Text(
                              dialogL10n.viewerCharactersCount(charCount),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(ctx).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(dialogL10n.cancel),
                ),
                FilledButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await Clipboard.setData(ClipboardData(text: text));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(l10n.viewerCopiedWordsChars(
                              wordCount, charCount)),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: Text(dialogL10n.copy),
                ),
              ],
            );
          },
        );
      }
    } catch (e) {
      _log.e('Error copying image extracted text', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.viewerErrorAccessText)),
        );
      }
    }
  }

  Widget _buildFloatingBottomPanel(BuildContext context, bool isDark) {
    final l10n = AppLocalizations.of(context)!;
    final canOpenSidebar = _canOpenSidebar();

    return Stack(
      children: [
        // Shadow above the bottom panel
        Positioned(
          top: -8,
          left: 0,
          right: 0,
          height: 8,
          child: Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.3)
                      : Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
          ),
        ),
        // Bottom panel container
        ClipRRect(
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(12),
            topRight: Radius.circular(12),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.95)
                    : Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.92),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Main control row
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {}, // Absorb taps but don't hide controls
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 2,
                      ),
                      child: Row(
                        children: [
                          // Left: hamburger
                          Opacity(
                            opacity: canOpenSidebar ? 1.0 : 0.5,
                            child: IgnorePointer(
                              ignoring: !canOpenSidebar,
                              child: AnimatedHamburgerIcon(
                                onPressed: _toggleSidebar,
                                isOpen: _sidebarOpen,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                          // Center: format-specific nav controls
                          Expanded(
                            child: Center(
                              child: _buildFormatSpecificControls(context),
                            ),
                          ),
                          // Right: expand button
                          _buildIconButton(
                            context,
                            _bottomMenuExpanded
                                ? Icons.expand_more
                                : Icons.expand_less,
                            _toggleBottomMenu,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Sheet selection info row (spreadsheets only)
                  if (_isSpreadsheet())
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: Theme.of(context)
                                .colorScheme
                                .outline
                                .withValues(alpha: 0.15),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (_sheetCellRef != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _sheetCellRef!,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimaryContainer,
                                    ),
                              ),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _sheetCellValue.isEmpty
                                  ? l10n.viewerTapCellToSeeValue
                                  : _sheetCellValue,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w500,
                                    color: _sheetCellValue.isEmpty
                                        ? Theme.of(context).colorScheme.outline
                                        : null,
                                  ),
                            ),
                          ),
                          if (_sheetCellValue.isNotEmpty)
                            IconButton(
                              icon: Icon(Icons.copy,
                                  size: 20,
                                  color: Theme.of(context).colorScheme.primary),
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                  minWidth: 40, minHeight: 40),
                              onPressed: () {
                                Clipboard.setData(
                                    ClipboardData(text: _sheetCellValue));
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(l10n.viewerCopied),
                                    duration: const Duration(milliseconds: 800),
                                  ),
                                );
                              },
                              tooltip: l10n.viewerCopyValue,
                            ),
                        ],
                      ),
                    ),
                  // Expandable menu
                  SizeTransition(
                    sizeFactor: CurvedAnimation(
                      parent: _menuController,
                      curve: Curves.easeInOutCubic,
                    ),
                    axisAlignment: -1.0,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Divider(
                          height: 1,
                          indent: 16,
                          endIndent: 16,
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.2),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(6),
                          child: _buildExpandedMenuContent(context),
                        ),
                      ],
                    ),
                  ),
                  // Keep controls above the system navigation / gesture bar.
                  SizedBox(height: MediaQuery.viewPaddingOf(context).bottom),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build format-specific controls for the center of the panel
  Widget _buildFormatSpecificControls(BuildContext context) {
    final docState = ref.watch(documentViewerProvider);
    if (docState.document == null) return const SizedBox.shrink();

    final format = docState.document!.format.toUpperCase();

    if (format == 'PDF') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIconButton(
            context,
            Icons.first_page,
            _currentPage > 1 ? _goToFirstPage : null,
          ),
          _buildIconButton(
            context,
            Icons.chevron_left,
            _currentPage > 1 ? _goToPreviousPage : null,
          ),
          _buildPageIndicator(context),
          _buildIconButton(
            context,
            Icons.chevron_right,
            _currentPage < _totalPages ? _goToNextPage : null,
          ),
          _buildIconButton(
            context,
            Icons.last_page,
            _currentPage < _totalPages ? _goToLastPage : null,
          ),
          if (!_textMode) ...[
            const SizedBox(width: 8),
            ViewerZoomPanelControls(
              zoom: _pdfZoom,
              minZoom: 0.25,
              maxZoom: 8.0,
              showFit: true,
              onZoomOut: () =>
                  (_pdfViewerKey.currentState as dynamic)?.zoomOut(),
              onZoomIn: () =>
                  (_pdfViewerKey.currentState as dynamic)?.zoomIn(),
              onFit: () =>
                  (_pdfViewerKey.currentState as dynamic)?.fitToWidth(),
            ),
          ],
        ],
      );
    } else if (_isTextLikeFormat(format)) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildIconButton(
            context,
            Icons.remove,
            _textFontSize > 12
                ? () => setState(
                    () => _textFontSize = (_textFontSize - 1).clamp(12, 32))
                : null,
          ),
          SizedBox(
            width: 50,
            child: Center(
              child: Text(
                '${_textFontSize.toStringAsFixed(0)}pt',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ),
          _buildIconButton(
            context,
            Icons.add,
            _textFontSize < 32
                ? () => setState(
                    () => _textFontSize = (_textFontSize + 1).clamp(12, 32))
                : null,
          ),
          const SizedBox(width: 8),
          _buildIconButton(
            context,
            _textWordWrap ? Icons.wrap_text : Icons.text_fields,
            () => setState(() => _textWordWrap = !_textWordWrap),
          ),
        ],
      );
    } else if (const {'PNG', 'JPG', 'JPEG', 'GIF', 'WEBP', 'BMP'}
        .contains(format)) {
      return ViewerZoomPanelControls(
        zoom: _imageZoom,
        minZoom: 0.5,
        maxZoom: 5.0,
        showFit: true,
        onZoomOut: () => _imageViewerKey.currentState?.zoomOut(),
        onZoomIn: () => _imageViewerKey.currentState?.zoomIn(),
        onFit: () => _imageViewerKey.currentState?.fitToView(),
      );
    } else if (isMediaFormat(widget.filePath)) {
      final media = _mediaViewerKey.currentState;
      if (media == null) return const SizedBox.shrink();
      return _buildMediaControls(context, media);
    }

    if (_isSpreadsheet()) {
      // Same zoom widget as PDF bottom bar (− / % / + / fit).
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ViewerZoomPanelControls(
            zoom: _sheetZoom,
            minZoom: 0.3,
            maxZoom: 3.0,
            showFit: true,
            onZoomOut: () => setState(
              () => _sheetZoom = (_sheetZoom - 0.15).clamp(0.3, 3.0),
            ),
            onZoomIn: () => setState(
              () => _sheetZoom = (_sheetZoom + 0.15).clamp(0.3, 3.0),
            ),
            onFit: () => setState(() => _sheetZoom = 1.0),
          ),
          const SizedBox(width: 4),
          _buildIconButton(
            context,
            Icons.fullscreen,
            _toggleFullscreen,
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  /// Build reactive media controls using ValueListenableBuilder to track position.
  /// Outer VLB listens to currentController so it rebinds automatically when
  /// MediaViewerState hot-swaps to the pre-warmed controller on replay.
  Widget _buildMediaControls(BuildContext context, MediaViewerState media) {
    return ValueListenableBuilder<VideoPlayerController?>(
      valueListenable: media.currentController,
      builder: (context, controller, _) {
        if (controller == null) return const SizedBox.shrink();
        return ValueListenableBuilder<VideoPlayerValue>(
          valueListenable: controller,
          builder: (context, value, child) {
            final theme = Theme.of(context);
            final pos = value.position;
            final dur = value.duration;
            final isPlaying = value.isPlaying;
            final posMs = dur.inMilliseconds > 0
                ? pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble()
                : 0.0;
            final durMs =
                dur.inMilliseconds > 0 ? dur.inMilliseconds.toDouble() : 1.0;

            return Row(
              children: [
                IconButton(
                  icon: Icon(
                      isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 20),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: media.togglePlay,
                ),
                Text(
                  MediaViewerState.formatDuration(
                    _sliderDragValue != null
                        ? Duration(milliseconds: _sliderDragValue!.toInt())
                        : pos,
                  ),
                  style: theme.textTheme.labelSmall,
                ),
                Expanded(
                  child: Slider(
                    value: (_sliderDragValue ?? posMs).clamp(0.0, durMs),
                    max: durMs,
                    onChangeStart: (v) {
                      _mediaWasPlaying = isPlaying;
                      if (isPlaying) media.pause();
                      setState(() => _sliderDragValue = v);
                    },
                    onChanged: (v) => setState(() => _sliderDragValue = v),
                    onChangeEnd: (v) {
                      setState(() => _sliderDragValue = null);
                      _onMediaSeekEnd(media, Duration(milliseconds: v.toInt()));
                    },
                  ),
                ),
                Text(MediaViewerState.formatDuration(dur),
                    style: theme.textTheme.labelSmall),
                const SizedBox(width: 4),
                ValueListenableBuilder<bool>(
                  valueListenable: media.loopNotifier,
                  builder: (context, isLooping, child) {
                    return IconButton(
                      icon: Icon(
                          isLooping
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          size: 18,
                          color: isLooping ? theme.colorScheme.primary : null),
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      onPressed: media.toggleLoop,
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Await seek completion, then resume playback if video was playing before drag.
  /// Awaiting is critical: ensures controller.value.position is updated before any
  /// subsequent play() call, preventing play() from auto-seeking to Duration.zero.
  Future<void> _onMediaSeekEnd(MediaViewerState media, Duration pos) async {
    await media.seekTo(pos);
    if (_mediaWasPlaying) {
      media.play();
    }
  }

  /// Build the expanded menu content (Copy, Invert, TextMode, Theme buttons)
  Widget _buildExpandedMenuContent(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final docState = ref.watch(documentViewerProvider);
    if (docState.document == null) return const SizedBox.shrink();

    final format = docState.document!.format.toUpperCase();

    if (format == 'PDF') {
      return Row(
        children: [
          Expanded(
            child: _buildTile(
              icon: Icons.copy_all,
              label: l10n.copy,
              onTap: _copyPdfText,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildTile(
              icon:
                  _invertColors ? Icons.brightness_high : Icons.brightness_low,
              label: l10n.viewerInvert,
              onTap: () => setState(
                () => _invertColors = !_invertColors,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _buildTile(
              icon: _textMode ? Icons.picture_as_pdf : Icons.text_snippet,
              label: _textMode ? 'PDF' : l10n.viewerText,
              onTap: () => setState(
                () => _textMode = !_textMode,
              ),
            ),
          ),
        ],
      );
    } else if (const {
      'TXT',
      'DOCX',
      'DOC',
      'RTF',
      'ODT',
      'OTT',
      'PPT',
      'PPTX',
      'ODP',
      'EPUB',
      'JAVA',
      'PY',
      'SH',
      'HTML',
      'MD',
      'LOG',
      'JSON',
      'XML',
      'FADREC'
    }.contains(format)) {
      final hasSyntax = _getHighlightLanguage(format) != null;
      return Row(
        children: [
          Expanded(
            child: _buildTile(
              icon: Icons.copy_all,
              label: l10n.copy,
              onTap: _copyDocumentText,
            ),
          ),
          const SizedBox(width: 8),
          if (hasSyntax) ...[
            Expanded(
              child: _buildTile(
                icon:
                    _syntaxHighlightEnabled ? Icons.code : Icons.code_outlined,
                label: l10n.viewerSyntax,
                onTap: () => setState(
                    () => _syntaxHighlightEnabled = !_syntaxHighlightEnabled),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: _buildTile(
              icon: Icons.font_download,
              label: l10n.viewerFont,
              onTap: () {
                // Toggle font between Mono and Ubuntu
                showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: Text(AppLocalizations.of(ctx)!.viewerFontStyle),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          title: Text(
                              AppLocalizations.of(ctx)!.viewerMonospaceCourier),
                          trailing: _textFontIsMonoFont
                              ? Icon(Icons.check,
                                  color: Theme.of(ctx).colorScheme.primary)
                              : null,
                          onTap: () {
                            setState(() => _textFontIsMonoFont = true);
                            Navigator.pop(ctx);
                          },
                        ),
                        ListTile(
                          title: Text(
                              AppLocalizations.of(ctx)!.viewerSystemUbuntu),
                          trailing: !_textFontIsMonoFont
                              ? Icon(Icons.check,
                                  color: Theme.of(ctx).colorScheme.primary)
                              : null,
                          onTap: () {
                            setState(() => _textFontIsMonoFont = false);
                            Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      );
    } else if (isMediaFormat(widget.filePath)) {
      return Row(
        children: [
          Expanded(
            child: _buildTile(
              icon: Icons.speed,
              label: l10n.viewerPlaybackSpeed,
              onTap: () =>
                  _showSpeedDialog(context, _mediaViewerKey.currentState),
            ),
          ),
        ],
      );
    } else if (const {'PNG', 'JPG', 'JPEG', 'GIF', 'WEBP', 'BMP'}
        .contains(format)) {
      return Row(
        children: [
          Expanded(
            child: _buildTile(
              icon: Icons.copy_all,
              label: l10n.copy,
              onTap: _copyImageExtractedText,
            ),
          ),
        ],
      );
    }

    if (_isSpreadsheet()) {
      return const SizedBox.shrink();
    }

    return const SizedBox.shrink();
  }

  Widget _buildSidebarDrawer(BuildContext context, bool isDark) {
    final drawerContent = _resolveSidebarContent(context);
    if (drawerContent == null) {
      return const SizedBox.shrink();
    }

    final maxWidth = MediaQuery.of(context).size.width * 0.8;
    final width = maxWidth < 280 ? maxWidth : 280.0;
    final theme = Theme.of(context);
    final bgColor = isDark
        ? theme.colorScheme.surface.withValues(alpha: 0.95)
        : theme.colorScheme.surface.withValues(alpha: 0.93);
    final borderColor = theme.colorScheme.outline.withValues(alpha: 0.2);
    final isRTL = Directionality.of(context) == TextDirection.rtl;

    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: _handleSidebarDragUpdate,
      onHorizontalDragEnd: _handleSidebarDragEnd,
      child: Transform.translate(
        offset: Offset(isRTL ? -_sidebarDragOffset : _sidebarDragOffset, 0),
        child: SizedBox(
          width: width + 20,
          child: ClipPath(
            clipper: _SidebarClipper(
              sidebarWidth: width,
              radius: _kSidebarRadius,
              isRTL: isRTL,
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // 1. Background and Flares with blurred appearance
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _InvertedCornerSidebarPainter(
                        color: bgColor,
                        borderColor: borderColor,
                        radius: _kSidebarRadius,
                        sidebarWidth: width,
                        isRTL: isRTL,
                      ),
                    ),
                  ),
                  // 2. Content (Sheet)
                  Positioned(
                    left: isRTL ? null : 0,
                    right: isRTL ? 0 : null,
                    top: _kSidebarRadius,
                    bottom: _kSidebarRadius,
                    width: width,
                    child: ClipRRect(
                      borderRadius: isRTL
                          ? const BorderRadius.only(
                              topLeft: Radius.circular(16),
                              bottomLeft: Radius.circular(16),
                            )
                          : const BorderRadius.only(
                              topRight: Radius.circular(16),
                              bottomRight: Radius.circular(16),
                            ),
                      child: Material(
                        color: Colors.transparent,
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.transparent,
                          ),
                          child: drawerContent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(
      BuildContext context, WidgetRef ref, ParsedDocumentState state) {
    final l10n = AppLocalizations.of(context)!;

    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 100),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(
                  state.error ?? l10n.viewerErrorLoadingDocument,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton.icon(
                onPressed: () {
                  ref
                      .read(documentViewerProvider.notifier)
                      .initializeAndLoad(widget.filePath, widget.fileName);
                },
                icon: const Icon(Icons.refresh),
                label: Text(l10n.settingsRetry),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l10n.viewerGoBack),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSpeedDialog(BuildContext context, MediaViewerState? media) {
    if (media == null) return;
    final speeds = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final l10n = AppLocalizations.of(context)!;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.viewerPlaybackSpeed),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: speeds.map((speed) {
            return ListTile(
              title: Text('${speed}x'),
              trailing: const Icon(Icons.check),
              onTap: () {
                media.setSpeed(speed);
                Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(l10n.viewerGoBack),
          ),
        ],
      ),
    );
  }
}

class _InvertedCornerSidebarPainter extends CustomPainter {
  final Color color;
  final Color borderColor;
  final double radius;
  final double sidebarWidth;
  final bool isRTL;

  _InvertedCornerSidebarPainter({
    required this.color,
    required this.borderColor,
    required this.radius,
    required this.sidebarWidth,
    this.isRTL = false,
  });

  double _x(double x, Size size) => isRTL ? size.width - x : x;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    Path buildPath(Size size) {
      final path = Path();

      path.moveTo(_x(0, size), 0);
      path.cubicTo(
        _x(0, size),
        radius * 0.4,
        _x(radius * 0.1, size),
        radius,
        _x(radius, size),
        radius,
      );
      path.lineTo(_x(sidebarWidth - 16, size), radius);
      path.arcToPoint(
        Offset(_x(sidebarWidth, size), radius + 16),
        radius: const Radius.circular(16),
        clockwise: !isRTL,
      );
      path.lineTo(_x(sidebarWidth, size), size.height - radius - 16);
      path.arcToPoint(
        Offset(_x(sidebarWidth - 16, size), size.height - radius),
        radius: const Radius.circular(16),
        clockwise: !isRTL,
      );
      path.lineTo(_x(radius, size), size.height - radius);
      path.cubicTo(
        _x(radius * 0.1, size),
        size.height - radius,
        _x(0, size),
        size.height - radius * 0.4,
        _x(0, size),
        size.height,
      );
      path.lineTo(_x(0, size), 0);
      path.close();
      return path;
    }

    final path = buildPath(size);
    canvas.drawShadow(path, Colors.black, 10, false);
    canvas.drawPath(path, paint);

    final borderPath = buildPath(size);
    canvas.drawPath(borderPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _InvertedCornerSidebarPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.borderColor != borderColor ||
      oldDelegate.isRTL != isRTL;
}

/// Custom clipper that matches the exact shape of the sidebar with flares
class _SidebarClipper extends CustomClipper<Path> {
  final double sidebarWidth;
  final double radius;
  final bool isRTL;

  _SidebarClipper({
    required this.sidebarWidth,
    required this.radius,
    this.isRTL = false,
  });

  double _x(double x, Size size) => isRTL ? size.width - x : x;

  @override
  Path getClip(Size size) {
    final path = Path();

    path.moveTo(_x(0, size), 0);
    path.cubicTo(
      _x(0, size),
      radius * 0.4,
      _x(radius * 0.1, size),
      radius,
      _x(radius, size),
      radius,
    );
    path.lineTo(_x(sidebarWidth - 16, size), radius);
    path.arcToPoint(
      Offset(_x(sidebarWidth, size), radius + 16),
      radius: const Radius.circular(16),
      clockwise: !isRTL,
    );
    path.lineTo(_x(sidebarWidth, size), size.height - radius - 16);
    path.arcToPoint(
      Offset(_x(sidebarWidth - 16, size), size.height - radius),
      radius: const Radius.circular(16),
      clockwise: !isRTL,
    );
    path.lineTo(_x(radius, size), size.height - radius);
    path.cubicTo(
      _x(radius * 0.1, size),
      size.height - radius,
      _x(0, size),
      size.height - radius * 0.4,
      _x(0, size),
      size.height,
    );
    path.lineTo(_x(0, size), 0);
    path.close();

    return path;
  }

  @override
  bool shouldReclip(covariant _SidebarClipper oldClipper) =>
      oldClipper.sidebarWidth != sidebarWidth ||
      oldClipper.radius != radius ||
      oldClipper.isRTL != isRTL;
}
