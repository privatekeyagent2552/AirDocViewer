import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'package:air_docs_viewer/features/viewer/data/services/platform_channel_service.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/sheet_entity.dart';
import 'package:air_docs_viewer/features/viewer/presentation/viewer_failure_message.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/professional_sheet_viewer.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// One rectangle of a workbook, plus at most the adjacent rectangle.
///
/// Scrolling to the edge loads the next rows or columns and drops the one
/// that is no longer next to the window on screen.
class ExcelSheetPager extends StatefulWidget {
  const ExcelSheetPager({
    super.key,
    required this.filePath,
    required this.format,
    this.sheetViewerKey,
    this.initialZoom = 1.0,
    this.onZoomChanged,
    this.onSelectionChanged,
    this.onWindowSettled,
  });

  final String filePath;
  final String format;
  final GlobalKey<ProfessionalSheetViewerState>? sheetViewerKey;
  final double initialZoom;
  final ValueChanged<double>? onZoomChanged;
  final void Function(String?, String)? onSelectionChanged;
  final VoidCallback? onWindowSettled;

  static const int windowRows = 200;
  static const int windowCols = 30;

  @override
  State<ExcelSheetPager> createState() => ExcelSheetPagerState();
}

class _Window {
  const _Window({
    required this.sheet,
    required this.startRow,
    required this.startCol,
    required this.hasMoreRows,
    required this.hasMoreCols,
    required this.rows,
    required this.sheetName,
  });

  final int sheet;
  final int startRow;
  final int startCol;
  final bool hasMoreRows;
  final bool hasMoreCols;
  final List<List<String>> rows;
  final String sheetName;

  int get rowCount => rows.length;
  int get colCount => rows.isEmpty ? 0 : rows.first.length;

  _Window copyWith({bool? hasMoreRows, bool? hasMoreCols}) {
    return _Window(
      sheet: sheet,
      startRow: startRow,
      startCol: startCol,
      hasMoreRows: hasMoreRows ?? this.hasMoreRows,
      hasMoreCols: hasMoreCols ?? this.hasMoreCols,
      rows: rows,
      sheetName: sheetName,
    );
  }
}

class _Grid {
  const _Grid({
    required this.rows,
    required this.rowOrigin,
    required this.colOrigin,
    required this.sheetName,
    required this.focusLocalRow,
    required this.focusLocalCol,
    required this.focusRowCount,
    required this.focusColCount,
    required this.moreBeforeRows,
    required this.moreAfterRows,
    required this.moreBeforeCols,
    required this.moreAfterCols,
    required this.prevRow,
    required this.nextRow,
    required this.prevCol,
    required this.nextCol,
    required this.anchorRow,
    required this.anchorCol,
  });

  final List<List<String>> rows;
  final int rowOrigin;
  final int colOrigin;
  final String sheetName;
  final int focusLocalRow;
  final int focusLocalCol;
  final int focusRowCount;
  final int focusColCount;
  final bool moreBeforeRows;
  final bool moreAfterRows;
  final bool moreBeforeCols;
  final bool moreAfterCols;
  final int prevRow;
  final int nextRow;
  final int prevCol;
  final int nextCol;
  final int anchorRow;
  final int anchorCol;
}

class ExcelSheetPagerState extends State<ExcelSheetPager> {
  static final _log = Logger();
  final _channel = MethodChannelService();

  final List<_Window> _held = [];
  _Window? _focus;
  List<String> _names = const [];

  int _gen = 0;
  int _token = 0;
  bool _loading = false;
  bool _freezeEdges = false;
  String? _errorRaw;
  DateTime _gatedAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get rowOrigin => _compose()?.rowOrigin ?? 0;
  int get colOrigin => _compose()?.colOrigin ?? 0;

  @override
  void initState() {
    super.initState();
    _open(sheet: 0, startRow: 0, startCol: 0);
  }

  @override
  void dispose() {
    _gen++;
    super.dispose();
  }

  List<Map<String, dynamic>> search(String query) {
    final grid = _compose();
    if (grid == null || query.isEmpty) return const [];
    final needle = query.toLowerCase();
    final results = <Map<String, dynamic>>[];
    for (var r = 0; r < grid.rows.length; r++) {
      final row = grid.rows[r];
      for (var c = 0; c < row.length; c++) {
        if (row[c].toLowerCase().contains(needle)) {
          results.add({'row': r, 'col': c, 'value': row[c]});
          if (results.length >= 30) return results;
        }
      }
    }
    return results;
  }

  _Window? _find(int sheet, int row, int col) {
    for (final window in _held) {
      if (window.sheet == sheet &&
          window.startRow == row &&
          window.startCol == col) {
        return window;
      }
    }
    return null;
  }

  bool _verticalNeighbor(_Window a, _Window b) {
    return a.sheet == b.sheet &&
        a.startCol == b.startCol &&
        (a.startRow - b.startRow).abs() == ExcelSheetPager.windowRows;
  }

  bool _horizontalNeighbor(_Window a, _Window b) {
    return a.sheet == b.sheet &&
        a.startRow == b.startRow &&
        (a.startCol - b.startCol).abs() == ExcelSheetPager.windowCols;
  }

  void _keep(_Window window) {
    _held.removeWhere(
      (held) =>
          held.sheet != window.sheet ||
          (held.startRow == window.startRow && held.startCol == window.startCol),
    );
    _held.add(window);
    _held.removeWhere((held) {
      if (identical(held, window)) return false;
      return !_verticalNeighbor(held, window) && !_horizontalNeighbor(held, window);
    });
    if (_held.length > 2) {
      _held.removeWhere((held) => !identical(held, window));
      if (!_held.contains(window)) _held.add(window);
    }
  }

  _Grid? _compose() {
    final focus = _focus;
    if (focus == null) return null;
    _Window? other;
    for (final held in _held) {
      if (identical(held, focus)) continue;
      if (_verticalNeighbor(held, focus) || _horizontalNeighbor(held, focus)) {
        other = held;
        break;
      }
    }

    var rows = focus.rows;
    var rowOrigin = focus.startRow;
    var colOrigin = focus.startCol;
    var stacked = false;
    var stitched = false;

    if (other != null && focus.rows.isNotEmpty && other.rows.isNotEmpty) {
      if (_verticalNeighbor(other, focus)) {
        final upper = focus.startRow <= other.startRow ? focus : other;
        final lower = identical(upper, focus) ? other : focus;
        final width = upper.colCount > lower.colCount ? upper.colCount : lower.colCount;
        List<String> pad(List<String> row) {
          if (row.length >= width) return row;
          return [...row, ...List.filled(width - row.length, '')];
        }

        rows = [...upper.rows.map(pad), ...lower.rows.map(pad)];
        rowOrigin = upper.startRow;
        colOrigin = upper.startCol;
        stacked = true;
      } else if (_horizontalNeighbor(other, focus) &&
          other.rowCount == focus.rowCount) {
        final left = focus.startCol <= other.startCol ? focus : other;
        final right = identical(left, focus) ? other : focus;
        rows = [
          for (var i = 0; i < left.rowCount; i++)
            [...left.rows[i], ...right.rows[i]],
        ];
        rowOrigin = left.startRow;
        colOrigin = left.startCol;
        stitched = true;
      }
    }

    final lower = stacked
        ? (focus.startRow >= (other?.startRow ?? focus.startRow) ? focus : other!)
        : focus;
    final upper = stacked
        ? (identical(lower, focus) ? other! : focus)
        : focus;
    final right = stitched
        ? (focus.startCol >= (other?.startCol ?? focus.startCol) ? focus : other!)
        : focus;
    final left = stitched
        ? (identical(right, focus) ? other! : focus)
        : focus;

    return _Grid(
      rows: rows,
      rowOrigin: rowOrigin,
      colOrigin: colOrigin,
      sheetName: focus.sheetName,
      focusLocalRow: focus.startRow - rowOrigin,
      focusLocalCol: focus.startCol - colOrigin,
      focusRowCount: focus.rowCount,
      focusColCount: focus.colCount,
      moreBeforeRows: upper.startRow > 0,
      moreAfterRows: lower.hasMoreRows,
      moreBeforeCols: left.startCol > 0,
      moreAfterCols: right.hasMoreCols,
      prevRow: upper.startRow - ExcelSheetPager.windowRows,
      nextRow: lower.startRow + ExcelSheetPager.windowRows,
      prevCol: left.startCol - ExcelSheetPager.windowCols,
      nextCol: right.startCol + ExcelSheetPager.windowCols,
      anchorRow: focus.startRow,
      anchorCol: focus.startCol,
    );
  }

  Future<void> _open({
    required int sheet,
    required int startRow,
    required int startCol,
    bool fromScroll = false,
    bool towardEnd = true,
    bool horizontal = false,
  }) async {
    final row = startRow < 0 ? 0 : startRow;
    final col = startCol < 0 ? 0 : startCol;
    if (fromScroll && _loading) return;
    final held = _find(sheet, row, col);
    if (held != null) {
      _show(
        held,
        fromScroll: fromScroll,
        towardEnd: towardEnd,
        horizontal: horizontal,
      );
      return;
    }
    final gen = ++_gen;
    if (mounted) setState(() => _loading = true);
    try {
      final raw = await _channel.readSheetWindow(
        filePath: widget.filePath,
        format: widget.format,
        sheetIndex: sheet,
        startRow: row,
        rowCount: ExcelSheetPager.windowRows,
        startCol: col,
        colCount: ExcelSheetPager.windowCols,
      );
      if (!mounted || gen != _gen) return;
      final names = [
        for (final name in (raw['sheetNames'] as List? ?? const <dynamic>[]))
          name.toString(),
      ];
      if (names.isNotEmpty) _names = names;
      final failed = raw['failed'] == true;
      final rows = _asRows(raw['rows']);
      final sheetName = (raw['sheetName']?.toString().isNotEmpty ?? false)
          ? raw['sheetName'].toString()
          : (sheet >= 0 && sheet < _names.length ? _names[sheet] : '');
      _log.i(
        'Sheet window $sheet rows=$row cols=$col '
        'got=${rows.length}x${rows.isEmpty ? 0 : rows.first.length} '
        'failed=$failed',
      );
      if (failed && rows.isEmpty) {
        setState(() {
          _loading = false;
          _errorRaw = 'PARSE_ERROR';
        });
        return;
      }
      if (rows.isEmpty && _focus != null && (row > 0 || col > 0)) {
        _stopPastEnd(row: row, col: col);
        return;
      }
      final window = _Window(
        sheet: sheet,
        startRow: (raw['startRow'] as num?)?.toInt() ?? row,
        startCol: (raw['startCol'] as num?)?.toInt() ?? col,
        hasMoreRows: raw['hasMoreRows'] == true,
        hasMoreCols: raw['hasMoreCols'] == true,
        rows: rows,
        sheetName: sheetName,
      );
      _show(
        window,
        fromScroll: fromScroll,
        towardEnd: towardEnd,
        horizontal: horizontal,
      );
    } catch (e, st) {
      _log.e('Excel window failed', error: e, stackTrace: st);
      if (!mounted || gen != _gen) return;
      setState(() {
        _loading = false;
        _errorRaw = e.toString();
      });
    }
  }

  void _stopPastEnd({required int row, required int col}) {
    final focus = _focus;
    if (focus == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final updated = focus.copyWith(
      hasMoreRows: row > focus.startRow ? false : focus.hasMoreRows,
      hasMoreCols: col > focus.startCol ? false : focus.hasMoreCols,
    );
    final index = _held.indexWhere(
      (held) =>
          held.sheet == focus.sheet &&
          held.startRow == focus.startRow &&
          held.startCol == focus.startCol,
    );
    if (index >= 0) _held[index] = updated;
    _focus = updated;
    if (!mounted) return;
    setState(() {
      _loading = false;
      _errorRaw = null;
    });
  }

  void _show(
    _Window window, {
    required bool fromScroll,
    required bool towardEnd,
    required bool horizontal,
  }) {
    _keep(window);
    _focus = window;
    _token++;
    _loading = false;
    _errorRaw = null;
    _freezeEdges = true;
    final grid = _compose();
    var jumpRow = 0;
    var jumpCol = 0;
    if (grid != null && fromScroll && !horizontal) {
      jumpRow = towardEnd
          ? grid.focusLocalRow
          : grid.focusLocalRow + grid.focusRowCount - 2;
    } else if (grid != null && fromScroll && horizontal) {
      jumpCol = towardEnd
          ? grid.focusLocalCol
          : grid.focusLocalCol + grid.focusColCount - 1;
    }
    if (jumpRow < 0) jumpRow = 0;
    if (jumpCol < 0) jumpCol = 0;
    final token = _token;
    if (!mounted) return;
    widget.onSelectionChanged?.call(null, '');
    widget.onWindowSettled?.call();
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || token != _token) return;
      widget.sheetViewerKey?.currentState?.jumpToLocalRow(jumpRow);
      widget.sheetViewerKey?.currentState?.jumpToLocalCol(jumpCol);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || token != _token) return;
        _freezeEdges = false;
      });
    });
  }

  List<List<String>> _asRows(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final row in raw)
        if (row is List)
          [for (final cell in row) cell?.toString() ?? '']
        else
          const <String>[],
    ];
  }

  bool _onGridScroll(ScrollNotification notification) {
    if (_freezeEdges || _loading) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final dragged = notification is ScrollUpdateNotification &&
        notification.dragDetails != null;
    final user = notification is ScrollEndNotification || dragged;
    if (!user) return false;
    final metrics = notification.metrics;
    if (metrics.maxScrollExtent <= 24) return false;
    final atEnd = metrics.pixels >= metrics.maxScrollExtent - 48;
    final atStart = metrics.pixels <= 1;
    if (!atEnd && !atStart) return false;
    final now = DateTime.now();
    if (now.difference(_gatedAt) < const Duration(milliseconds: 500)) {
      return false;
    }
    final grid = _compose();
    if (grid == null) return false;
    if (metrics.axis == Axis.vertical) {
      if (atEnd && grid.moreAfterRows) {
        _gatedAt = now;
        _open(
          sheet: _focus?.sheet ?? 0,
          startRow: grid.nextRow,
          startCol: grid.anchorCol,
          fromScroll: true,
          towardEnd: true,
        );
      } else if (atStart && grid.moreBeforeRows) {
        _gatedAt = now;
        _open(
          sheet: _focus?.sheet ?? 0,
          startRow: grid.prevRow,
          startCol: grid.anchorCol,
          fromScroll: true,
          towardEnd: false,
        );
      }
    } else if (metrics.axis == Axis.horizontal) {
      if (atEnd && grid.moreAfterCols) {
        _gatedAt = now;
        _open(
          sheet: _focus?.sheet ?? 0,
          startRow: grid.anchorRow,
          startCol: grid.nextCol,
          fromScroll: true,
          towardEnd: true,
          horizontal: true,
        );
      } else if (atStart && grid.moreBeforeCols) {
        _gatedAt = now;
        _open(
          sheet: _focus?.sheet ?? 0,
          startRow: grid.anchorRow,
          startCol: grid.prevCol,
          fromScroll: true,
          towardEnd: false,
          horizontal: true,
        );
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final grid = _compose();
    final waiting = _loading && grid == null;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          if (_names.length > 1) _sheetBar(),
          if (grid != null && grid.rows.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
              child: Text(
                l10n.viewerSheetWindowRange(
                  grid.rowOrigin + 1,
                  grid.rowOrigin + grid.rows.length,
                  spreadsheetColumnLabel(grid.colOrigin),
                  spreadsheetColumnLabel(
                    grid.colOrigin +
                        (grid.rows.first.isEmpty ? 0 : grid.rows.first.length - 1),
                  ),
                ),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          if (_errorRaw != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text(
                viewerFailureMessage(l10n, _errorRaw),
                textAlign: TextAlign.center,
              ),
            ),
          if (_loading && grid != null)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: waiting
                ? const Center(child: CircularProgressIndicator())
                : grid == null
                    ? _errorRaw != null
                        ? const SizedBox.shrink()
                        : Center(
                            child: Text(
                              l10n.documentNoSheets(widget.format),
                            ),
                          )
                    : grid.rows.isEmpty
                        ? Center(child: Text(l10n.sheetNoData(grid.sheetName)))
                        : NotificationListener<ScrollNotification>(
                            onNotification: _onGridScroll,
                            child: ProfessionalSheetViewer(
                              key: widget.sheetViewerKey,
                              sheet: SheetEntity(
                                name: grid.sheetName,
                                rows: grid.rows,
                                rowCount: grid.rows.length,
                                colCount: grid.rows.first.length,
                              ),
                              rowOrigin: grid.rowOrigin,
                              colOrigin: grid.colOrigin,
                              windowToken: _token,
                              initialZoom: widget.initialZoom,
                              onZoomChanged: widget.onZoomChanged,
                              onSelectionChanged: widget.onSelectionChanged,
                            ),
                          ),
          ),
        ],
      ),
    );
  }

  Widget _sheetBar() {
    final focus = _focus?.sheet ?? 0;
    return SizedBox(
      height: 44,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _names.length,
        itemBuilder: (context, index) {
          final selected = index == focus;
          return TextButton(
            onPressed: selected
                ? null
                : () => _open(sheet: index, startRow: 0, startCol: 0),
            child: Text(
              _names[index],
              style: TextStyle(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                decoration: selected ? TextDecoration.underline : null,
              ),
            ),
          );
        },
      ),
    );
  }
}
