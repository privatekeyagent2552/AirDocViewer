import 'package:flutter/material.dart';

/// Floating zoom pill used by DOCX and PDF (matches DOCX viewer UI).
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
              width: 40,
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
            if (onFit != null) ...[
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 2),
                color: theme.dividerColor.withValues(alpha: 0.45),
              ),
              IconButton(
                tooltip: fitTooltip,
                icon: const _FitResetIcon(size: 20),
                iconSize: 20,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                onPressed: onFit,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fat fit/reset icon: corner brackets + solid center bar (DOCX-style).
class _FitResetIcon extends StatelessWidget {
  const _FitResetIcon({this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _FitResetIconPainter(color: color),
      ),
    );
  }
}

class _FitResetIconPainter extends CustomPainter {
  _FitResetIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.12
      ..strokeCap = StrokeCap.square
      ..strokeJoin = StrokeJoin.miter;

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;
    final inset = w * 0.08;
    final arm = w * 0.28;

    // Four corner brackets (fatter than Material fit_screen).
    final left = inset;
    final top = inset;
    final right = w - inset;
    final bottom = h - inset;

    // Top-left
    canvas.drawLine(Offset(left, top), Offset(left + arm, top), stroke);
    canvas.drawLine(Offset(left, top), Offset(left, top + arm), stroke);
    // Top-right
    canvas.drawLine(Offset(right, top), Offset(right - arm, top), stroke);
    canvas.drawLine(Offset(right, top), Offset(right, top + arm), stroke);
    // Bottom-left
    canvas.drawLine(Offset(left, bottom), Offset(left + arm, bottom), stroke);
    canvas.drawLine(Offset(left, bottom), Offset(left, bottom - arm), stroke);
    // Bottom-right
    canvas.drawLine(Offset(right, bottom), Offset(right - arm, bottom), stroke);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - arm), stroke);

    // Solid center bar (the "small black box").
    final barW = w * 0.42;
    final barH = h * 0.22;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(w / 2, h / 2),
        width: barW,
        height: barH,
      ),
      Radius.circular(barH * 0.2),
    );
    canvas.drawRRect(rect, fill);
  }

  @override
  bool shouldRepaint(covariant _FitResetIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// Bottom-panel zoom row — compact, shared by Excel / images.
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
            icon: const _FitResetIcon(size: 16),
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
