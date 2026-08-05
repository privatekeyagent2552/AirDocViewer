import 'dart:io';
import 'package:flutter/material.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// Full-bleed image viewer with pinch-to-zoom and programmatic zoom controls.
class ImageViewer extends StatefulWidget {
  const ImageViewer({
    required this.filePath,
    this.onTap,
    this.onZoomChanged,
    super.key,
  });

  final String filePath;
  final VoidCallback? onTap;
  final ValueChanged<double>? onZoomChanged;

  @override
  State<ImageViewer> createState() => ImageViewerState();
}

class ImageViewerState extends State<ImageViewer> {
  final TransformationController _transform = TransformationController();

  static const _minZoom = 0.5;
  static const _maxZoom = 5.0;
  static const _zoomStep = 0.15;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_notifyZoom);
    WidgetsBinding.instance.addPostFrameCallback((_) => _notifyZoom());
  }

  @override
  void dispose() {
    _transform.removeListener(_notifyZoom);
    _transform.dispose();
    super.dispose();
  }

  double get currentZoom => _transform.value.getMaxScaleOnAxis().clamp(_minZoom, _maxZoom);

  void _notifyZoom() {
    widget.onZoomChanged?.call(currentZoom);
  }

  void zoomIn() => _setZoom(currentZoom + _zoomStep);

  void zoomOut() => _setZoom(currentZoom - _zoomStep);

  void fitToView() {
    _transform.value = Matrix4.identity();
    _notifyZoom();
  }

  void _setZoom(double zoom) {
    final clamped = zoom.clamp(_minZoom, _maxZoom);
    final current = currentZoom;
    if ((clamped - current).abs() < 0.001) return;
    final factor = clamped / current;
    final m = _transform.value.clone()
      ..translateByDouble(0, 0, 0, 1)
      ..scaleByDouble(factor, factor, factor, 1);
    _transform.value = m;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: _minZoom,
        maxScale: _maxZoom,
        child: Center(
          child: Image.file(
            File(widget.filePath),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) {
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.broken_image_outlined,
                      size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  Text(AppLocalizations.of(context)!.imageFailedToLoad,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
