import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';

/// Honest text-only viewer for legacy binary `.ppt`.
///
/// Does **not** invent colors, charts, or layout — that would be a false
/// rendering of the original deck. Visual design requires a ZIP `.pptx`.
class PresentationSlidesViewer extends StatefulWidget {
  const PresentationSlidesViewer({
    super.key,
    required this.slides,
    this.onTap,
    this.zoom = 1.0,
    this.onZoomChanged,
    this.showLegacyNotice = true,
  });

  final List<SlideEntity> slides;
  final VoidCallback? onTap;
  final double zoom;
  final ValueChanged<double>? onZoomChanged;
  final bool showLegacyNotice;

  static const double minZoom = 0.5;
  static const double maxZoom = 2.5;
  static const double zoomStep = 0.15;

  @override
  State<PresentationSlidesViewer> createState() =>
      PresentationSlidesViewerState();
}

class PresentationSlidesViewerState extends State<PresentationSlidesViewer> {
  final _log = Logger();
  late final PageController _pageController;
  int _index = 0;
  double _pinchStartZoom = 1.0;

  double get currentZoom => widget.zoom.clamp(
        PresentationSlidesViewer.minZoom,
        PresentationSlidesViewer.maxZoom,
      );

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _log.d('PresentationSlidesViewer text-only slides=${widget.slides.length}');
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void zoomIn() => _setZoom(currentZoom + PresentationSlidesViewer.zoomStep);

  void zoomOut() => _setZoom(currentZoom - PresentationSlidesViewer.zoomStep);

  void fitToWidth() {
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_index);
    }
    _setZoom(1.0);
  }

  void _setZoom(double zoom) {
    final next = zoom.clamp(
      PresentationSlidesViewer.minZoom,
      PresentationSlidesViewer.maxZoom,
    );
    if ((next - widget.zoom).abs() < 0.005) return;
    widget.onZoomChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.slides.isEmpty) {
      return Center(
        child: Text(
          'No slide text found in this .ppt file.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          if (widget.showLegacyNotice)
            Material(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.onErrorContainer,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Text only — not the original slide design. '
                        'This is a legacy .ppt file. Save as .pptx in PowerPoint '
                        'to see colors, images, and charts.',
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              onTap: widget.onTap,
              onScaleStart: (_) => _pinchStartZoom = widget.zoom,
              onScaleUpdate: (d) => _setZoom(_pinchStartZoom * d.scale),
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.slides.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (context, i) {
                  final slide = widget.slides[i];
                  final text = slide.text.trim();
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Transform.scale(
                      scale: currentZoom,
                      alignment: Alignment.topLeft,
                      child: Align(
                        alignment: Alignment.topLeft,
                        child: SingleChildScrollView(
                          child: SelectableText(
                            text.isEmpty
                                ? '(No text on slide ${slide.slideNumber})'
                                : text,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 72, top: 4),
              child: Text(
                'Slide ${_index + 1} of ${widget.slides.length}  ·  text only',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
