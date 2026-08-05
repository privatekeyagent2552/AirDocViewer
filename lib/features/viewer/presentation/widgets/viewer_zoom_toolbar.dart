import 'package:flutter/material.dart';

/// Floating zoom controls for DOCX (compact so they don't cover content).
class ViewerZoomToolbar extends StatelessWidget {
  const ViewerZoomToolbar({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    this.onFit,
    this.minZoom = 0.25,
    this.maxZoom = 3.0,
    this.fitTooltip = 'Fit width',
  });

  final double zoom;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback? onFit;
  final double minZoom;
  final double maxZoom;
  final String fitTooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canZoomOut = zoom > minZoom + 0.001;
    final canZoomIn = zoom < maxZoom - 0.001;
    return Material(
      elevation: 3,
      color: theme.colorScheme.surface.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Zoom out',
              icon: const Icon(Icons.remove, size: 18),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: canZoomOut ? onZoomOut : null,
            ),
            SizedBox(
              width: 36,
              child: Text(
                '${(zoom * 100).round()}%',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Zoom in',
              icon: const Icon(Icons.add, size: 18),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
              onPressed: canZoomIn ? onZoomIn : null,
            ),
            if (onFit != null)
              IconButton(
                tooltip: fitTooltip,
                icon: const Icon(Icons.fit_screen, size: 17),
                iconSize: 17,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                onPressed: onFit,
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom-panel zoom row — compact, shared by PDF / Excel / images.
class ViewerZoomPanelControls extends StatelessWidget {
  const ViewerZoomPanelControls({
    super.key,
    required this.zoom,
    required this.onZoomIn,
    required this.onZoomOut,
    this.onFit,
    this.minZoom = 0.25,
    this.maxZoom = 3.0,
    this.showFit = false,
  });

  final double zoom;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;
  final VoidCallback? onFit;
  final double minZoom;
  final double maxZoom;
  final bool showFit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: const Icon(Icons.remove, size: 16),
          iconSize: 16,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: zoom > minZoom + 0.001 ? onZoomOut : null,
        ),
        SizedBox(
          width: 40,
          child: Center(
            child: Text(
              '${(zoom * 100).round()}%',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add, size: 16),
          iconSize: 16,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: zoom < maxZoom - 0.001 ? onZoomIn : null,
        ),
        if (showFit && onFit != null) ...[
          IconButton(
            icon: const Icon(Icons.fit_screen, size: 16),
            iconSize: 16,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            onPressed: onFit,
            tooltip: 'Fit width',
          ),
        ],
      ],
    );
  }
}
