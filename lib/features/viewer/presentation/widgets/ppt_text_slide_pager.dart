import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'package:air_docs_viewer/features/viewer/data/services/platform_channel_service.dart';
import 'package:air_docs_viewer/features/viewer/presentation/viewer_failure_message.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// Text-only pager for legacy binary `.ppt`.
///
/// Visual rendering would construct a slideshow and decode every picture.
/// This keeps the text of the current slide and at most one neighbor.
class PptTextSlidePager extends StatefulWidget {
  const PptTextSlidePager({
    super.key,
    required this.filePath,
    this.onTap,
    this.zoom = 1.0,
    this.onZoomChanged,
  });

  final String filePath;
  final VoidCallback? onTap;
  final double zoom;
  final ValueChanged<double>? onZoomChanged;

  static const double minZoom = 0.5;
  static const double maxZoom = 2.5;
  static const double zoomStep = 0.15;

  @override
  State<PptTextSlidePager> createState() => PptTextSlidePagerState();
}

class PptTextSlidePagerState extends State<PptTextSlidePager> {
  final _log = Logger();
  final _channel = MethodChannelService();
  final Map<int, String> _texts = {};
  final Set<int> _failed = {};

  int _gen = 0;
  int _shown = 0;
  int _count = 0;
  int? _drag;
  bool _loading = true;
  bool _empty = false;
  bool _openFailed = false;
  String? _errorRaw;
  double _pinchStartZoom = 1.0;

  double get currentZoom => widget.zoom.clamp(
        PptTextSlidePager.minZoom,
        PptTextSlidePager.maxZoom,
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

  void zoomIn() => _setZoom(currentZoom + PptTextSlidePager.zoomStep);

  void zoomOut() => _setZoom(currentZoom - PptTextSlidePager.zoomStep);

  void fitToWidth() => _setZoom(1.0);

  void _setZoom(double zoom) {
    final next = zoom.clamp(
      PptTextSlidePager.minZoom,
      PptTextSlidePager.maxZoom,
    );
    if ((next - widget.zoom).abs() < 0.005) return;
    widget.onZoomChanged?.call(next);
  }

  int _labelIndex() {
    final raw = _drag ?? _shown;
    if (_count <= 0) return 0;
    return raw.clamp(0, _count - 1);
  }

  Future<void> _goTo(int index) async {
    if (_count > 0) {
      index = index.clamp(0, _count - 1);
    } else if (index < 0) {
      index = 0;
    }
    final gen = ++_gen;
    if (_texts.containsKey(index)) {
      _retain(index);
      if (!mounted || gen != _gen) return;
      setState(() => _shown = index);
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final page = await _channel.readPptSlide(
        filePath: widget.filePath,
        index: index,
      );
      if (!mounted || gen != _gen) return;
      final count = (page['slideCount'] as num?)?.toInt() ?? 0;
      final text = page['text']?.toString() ?? '';
      _log.i('PPT text slide $index of $count chars=${text.length}');
      if (count <= 0) {
        setState(() {
          _count = 0;
          _empty = true;
          _loading = false;
          _openFailed = false;
        });
        return;
      }
      final safe = index.clamp(0, count - 1);
      if (safe != index) {
        _count = count;
        await _goTo(safe);
        return;
      }
      _texts[index] = text;
      _failed.remove(index);
      _retain(index);
      setState(() {
        _count = count;
        _shown = index;
        _empty = false;
        _loading = false;
        _openFailed = false;
      });
    } catch (e, st) {
      _log.e('PPT slide read failed', error: e, stackTrace: st);
      if (!mounted || gen != _gen) return;
      if (_count == 0) {
        setState(() {
          _openFailed = true;
          _errorRaw = e.toString();
          _loading = false;
        });
        return;
      }
      _texts.remove(index);
      _failed.add(index);
      _retain(index);
      setState(() {
        _shown = index;
        _loading = false;
      });
    }
  }

  /// Current slide plus one adjacent slide already read. Anything else goes.
  void _retain(int index) {
    int? neighbor;
    if (_texts.containsKey(index - 1)) {
      neighbor = index - 1;
    } else if (_texts.containsKey(index + 1)) {
      neighbor = index + 1;
    }
    _texts.removeWhere((key, _) => key != index && key != neighbor);
    _failed.removeWhere((key) => key != index && key != neighbor);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    if (_openFailed) {
      return ColoredBox(
        color: theme.colorScheme.surface,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              viewerFailureMessage(l10n, _errorRaw),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final index = _labelIndex();
    final text = _texts[_shown];
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Text(
                l10n.viewerPptTextOnly,
                style: theme.textTheme.labelMedium?.copyWith(height: 1.35),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTap,
              onScaleStart: (_) => _pinchStartZoom = widget.zoom,
              onScaleUpdate: (d) => _setZoom(_pinchStartZoom * d.scale),
              child: _loading && text == null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(l10n.viewerOpeningPresentation),
                        ],
                      ),
                    )
                  : _empty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              l10n.viewerNoSlides,
                              textAlign: TextAlign.center,
                            ),
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
                                  _failed.contains(_shown)
                                      ? l10n.viewerSlideDrawFailed
                                      : (text ?? '').trim().isEmpty
                                          ? l10n.viewerNoSlideText
                                          : text!.trim(),
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
          if (_count > 0)
            Material(
              color: theme.colorScheme.surfaceContainerHigh,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: l10n.viewerPreviousSlide,
                        onPressed: index > 0 ? () => _goTo(index - 1) : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: _count <= 1
                            ? Text(
                                l10n.viewerSlidePosition(index + 1, _count),
                                textAlign: TextAlign.center,
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    l10n.viewerSlidePosition(index + 1, _count),
                                    style: theme.textTheme.labelMedium,
                                  ),
                                  Slider(
                                    value: index.toDouble(),
                                    min: 0,
                                    max: (_count - 1).toDouble(),
                                    onChanged: (v) =>
                                        setState(() => _drag = v.round()),
                                    onChangeEnd: (v) {
                                      setState(() => _drag = null);
                                      _goTo(v.round());
                                    },
                                  ),
                                ],
                              ),
                      ),
                      IconButton(
                        tooltip: l10n.viewerNextSlide,
                        onPressed: index < _count - 1
                            ? () => _goTo(index + 1)
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
