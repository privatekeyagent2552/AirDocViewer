import 'package:flutter/material.dart';

/// Pinch-to-zoom that still works above a [ListView] or [SelectionArea].
///
/// [GestureDetector.onScaleUpdate] loses the gesture arena to scroll/select.
/// This tracks raw pointers (same idea as the DOCX/PPTX WebView pinch path).
class PinchZoomListener extends StatefulWidget {
  const PinchZoomListener({
    super.key,
    required this.currentZoom,
    required this.onZoom,
    required this.child,
  });

  final double Function() currentZoom;
  final ValueChanged<double> onZoom;
  final Widget child;

  @override
  State<PinchZoomListener> createState() => _PinchZoomListenerState();
}

class _PinchZoomListenerState extends State<PinchZoomListener> {
  final Map<int, Offset> _points = {};
  double? _startDistance;
  double _startZoom = 1.0;

  double _distance() {
    final pts = _points.values.toList(growable: false);
    return (pts[0] - pts[1]).distance;
  }

  void _down(PointerDownEvent event) {
    _points[event.pointer] = event.position;
    if (_points.length == 2) {
      _startDistance = _distance();
      _startZoom = widget.currentZoom();
    }
  }

  void _move(PointerMoveEvent event) {
    if (!_points.containsKey(event.pointer)) return;
    _points[event.pointer] = event.position;
    if (_points.length < 2) return;
    final start = _startDistance;
    if (start == null || start < 8) return;
    widget.onZoom(_startZoom * (_distance() / start));
  }

  void _up(int pointer) {
    _points.remove(pointer);
    if (_points.length < 2) {
      _startDistance = null;
    } else {
      _startDistance = _distance();
      _startZoom = widget.currentZoom();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: (event) => _up(event.pointer),
      onPointerCancel: (event) => _up(event.pointer),
      child: widget.child,
    );
  }
}
