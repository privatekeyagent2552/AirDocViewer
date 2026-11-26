import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'package:air_docs_viewer/features/viewer/data/services/platform_channel_service.dart';
import 'package:air_docs_viewer/features/viewer/presentation/viewer_failure_message.dart';
import 'package:air_docs_viewer/features/viewer/presentation/word_paging.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// Text window for a Word file that must not be loaded whole.
///
/// Keeps the paragraphs on screen and at most one neighboring window.
/// Pictures are not read.
class WordBlockPager extends StatefulWidget {
  const WordBlockPager({
    super.key,
    required this.filePath,
    required this.format,
    this.onTap,
    this.zoom = 1.0,
    this.onZoomChanged,
  });

  final String filePath;
  final String format;
  final VoidCallback? onTap;
  final double zoom;
  final ValueChanged<double>? onZoomChanged;

  static const int windowBlocks = WordPaging.windowBlocks;
  static const double minZoom = 0.5;
  static const double maxZoom = 2.5;
  static const double zoomStep = 0.15;

  @override
  State<WordBlockPager> createState() => WordBlockPagerState();
}

class _Block {
  const _Block({required this.text, required this.skipped});

  final String text;
  final bool skipped;
}

class _WordWindow {
  const _WordWindow({
    required this.start,
    required this.blocks,
    required this.hasMore,
    required this.failed,
  });

  final int start;
  final List<_Block> blocks;
  final bool hasMore;
  final bool failed;

  _WordWindow copyWith({bool? hasMore}) {
    return _WordWindow(
      start: start,
      blocks: blocks,
      hasMore: hasMore ?? this.hasMore,
      failed: failed,
    );
  }
}

class WordBlockPagerState extends State<WordBlockPager> {
  final _log = Logger();
  final _channel = MethodChannelService();
  final Map<int, _WordWindow> _windows = {};

  int _gen = 0;
  int _shown = 0;
  bool _loading = true;
  double _pinchStartZoom = 1.0;

  double get currentZoom => widget.zoom.clamp(
        WordBlockPager.minZoom,
        WordBlockPager.maxZoom,
      );

  @override
  void initState() {
    super.initState();
    _goTo(0);
  }

  @override
  void dispose() {
    _gen++;
    super.dispose();
  }

  void zoomIn() => _setZoom(currentZoom + WordBlockPager.zoomStep);

  void zoomOut() => _setZoom(currentZoom - WordBlockPager.zoomStep);

  void fitToWidth() => _setZoom(1.0);

  void _setZoom(double zoom) {
    final next = zoom.clamp(WordBlockPager.minZoom, WordBlockPager.maxZoom);
    if ((next - widget.zoom).abs() < 0.005) return;
    widget.onZoomChanged?.call(next);
  }

  Future<void> _goTo(int start) async {
    if (start < 0) start = 0;
    final gen = ++_gen;
    final held = _windows[start];
    if (held != null) {
      _retain(start);
      if (!mounted || gen != _gen) return;
      setState(() => _shown = start);
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final page = await _channel.readWordWindow(
        filePath: widget.filePath,
        format: widget.format,
        start: start,
      );
      if (!mounted || gen != _gen) return;
      final blocks = _blocksOf(page['blocks']);
      final failed = page['failed'] == true;
      final hasMore = page['hasMore'] == true;
      _log.i(
        'Word window $start ${widget.format} blocks=${blocks.length} '
        'hasMore=$hasMore failed=$failed',
      );
      if (!failed && blocks.isEmpty && start > 0) {
        _stopPastEnd(start, gen);
        return;
      }
      final window = _WordWindow(
        start: (page['start'] as num?)?.toInt() ?? start,
        blocks: blocks,
        hasMore: hasMore,
        failed: failed,
      );
      _windows[window.start] = window;
      _retain(window.start);
      setState(() {
        _shown = window.start;
        _loading = false;
      });
    } catch (e, st) {
      _log.e('Word window read failed', error: e, stackTrace: st);
      if (!mounted || gen != _gen) return;
      final window = _WordWindow(
        start: start,
        blocks: const [],
        hasMore: true,
        failed: true,
      );
      _windows[start] = window;
      _retain(start);
      setState(() {
        _shown = start;
        _loading = false;
      });
    }
  }

  /// An empty read past the last paragraph is not a failure.
  void _stopPastEnd(int start, int gen) {
    final prev = start - WordBlockPager.windowBlocks;
    final held = _windows[prev];
    if (held != null) {
      _windows[prev] = held.copyWith(hasMore: false);
      _retain(prev);
      if (!mounted || gen != _gen) return;
      setState(() {
        _shown = prev;
        _loading = false;
      });
      return;
    }
    final window = _WordWindow(
      start: start,
      blocks: const [],
      hasMore: false,
      failed: false,
    );
    _windows[start] = window;
    _retain(start);
    if (!mounted || gen != _gen) return;
    setState(() {
      _shown = start;
      _loading = false;
    });
  }

  List<_Block> _blocksOf(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          _Block(
            text: item['text']?.toString() ?? '',
            skipped: item['skipped'] == true,
          ),
    ];
  }

  /// Current window plus one neighbor already read. Anything else goes.
  void _retain(int start) {
    final prev = start - WordBlockPager.windowBlocks;
    final next = start + WordBlockPager.windowBlocks;
    final neighbor = _windows.containsKey(prev)
        ? prev
        : _windows.containsKey(next)
            ? next
            : null;
    _windows.removeWhere((key, _) => key != start && key != neighbor);
  }

  String _body(AppLocalizations l10n, _WordWindow window) {
    if (window.failed) return viewerFailureMessage(l10n, 'FILE_OPEN_FAILED');
    if (window.blocks.isEmpty) {
      return window.start == 0 ? l10n.viewerWordNoText : '';
    }
    return window.blocks
        .map(
          (block) =>
              block.skipped ? l10n.viewerWordSectionSkipped : block.text,
        )
        .join('\n\n');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final window = _windows[_shown];
    final from = (window?.start ?? _shown) + 1;
    final count = window?.blocks.length ?? 0;
    final to = count == 0 ? from : (window?.start ?? _shown) + count;
    final canPrev = (window?.start ?? 0) > 0;
    final canNext = window != null && window.hasMore;

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                l10n.viewerWordTextOnly,
                style: theme.textTheme.labelMedium?.copyWith(height: 1.35),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTap,
              onScaleStart: (_) => _pinchStartZoom = widget.zoom,
              onScaleUpdate: (d) => _setZoom(_pinchStartZoom * d.scale),
              child: _loading && window == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(l10n.viewerOpeningDocument),
                        ],
                      ),
                    )
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Transform.scale(
                        scale: currentZoom,
                        alignment: Alignment.topLeft,
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              window == null ? '' : _body(l10n, window),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                height: 1.4,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          Material(
            color: theme.colorScheme.surfaceContainerHigh,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: l10n.viewerWordPrevious,
                      onPressed: canPrev && !_loading
                          ? () => _goTo(
                                (window?.start ?? _shown) -
                                    WordBlockPager.windowBlocks,
                              )
                          : null,
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        l10n.viewerWordWindowRange(from, to),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: l10n.viewerWordNext,
                      onPressed: canNext && !_loading
                          ? () => _goTo(
                                window.start + WordBlockPager.windowBlocks,
                              )
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
