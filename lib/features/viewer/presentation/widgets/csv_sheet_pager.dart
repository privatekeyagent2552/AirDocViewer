import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

import 'package:air_docs_viewer/features/viewer/data/services/csv_window_reader.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/sheet_entity.dart';
import 'package:air_docs_viewer/features/viewer/presentation/viewer_failure_message.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/professional_sheet_viewer.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// CSV grid read from disk, 200 rows by 30 columns, plus one neighbor.
///
/// Scrolling to the edge loads the next records or columns and drops the
/// window that is no longer beside the one on screen.
class CsvSheetPager extends StatefulWidget {
  const CsvSheetPager({
    super.key,
    required this.filePath,
    this.sheetViewerKey,
    this.initialZoom = 1.0,
    this.onZoomChanged,
    this.onSelectionChanged,
    this.onWindowSettled,
  });

  final String filePath;
  final GlobalKey<ProfessionalSheetViewerState>? sheetViewerKey;
  final double initialZoom;
  final ValueChanged<double>? onZoomChanged;
  final void Function(String?, String)? onSelectionChanged;
  final VoidCallback? onWindowSettled;

  @override
  State<CsvSheetPager> createState() => CsvSheetPagerState();
}

class _Window {
  const _Window({
    required this.startRow,
    required this.startCol,
    required this.startByte,
    required this.hasMoreRows,
    required this.hasMoreCols,
    required this.rows,
  });

  final int startRow;
  final int startCol;
  final int startByte;
  final bool hasMoreRows;
  final bool hasMoreCols;
  final List<List<String>> rows;

  int get rowCount => rows.length;
  int get colCount => rows.isEmpty ? 0 : rows.first.length;

  _Window copyWith({bool? hasMoreRows, bool? hasMoreCols}) {
    return _Window(
      startRow: startRow,
      startCol: startCol,
      startByte: startByte,
      hasMoreRows: hasMoreRows ?? this.hasMoreRows,
      hasMoreCols: hasMoreCols ?? this.hasMoreCols,
      rows: rows,
    );
  }
}

class _Grid {
  const _Grid({
    required this.rows,
    required this.rowOrigin,
    required this.colOrigin,
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

class CsvSheetPagerState extends State<CsvSheetPager> {
  static final _log = Logger();
  static const _sheetName = 'Sheet1';

  final List<_Window> _held = [];
  final Map<int, int> _anchors = {};
  _Window? _focus;

  int _gen = 0;
  int _token = 0;
  bool _loading = true;
  bool _freezeEdges = false;
  String? _errorRaw;
  DateTime _gatedAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get rowOrigin => _compose()?.rowOrigin ?? 0;
  int get colOrigin => _compose()?.colOrigin ?? 0;

  @override
  void initState() {
    super.initState();
    _open(startRow: 0, startCol: 0);
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

  _Window? _find(int row, int col) {
    for (final window in _held) {
      if (window.startRow == row && window.startCol == col) return window;
    }
    return null;
  }

  bool _verticalNeighbor(_Window a, _Window b) {
    return a.startCol == b.startCol &&
        (a.startRow - b.startRow).abs() == CsvWindowReader.windowRows;
  }

  bool _horizontalNeighbor(_Window a, _Window b) {
    return a.startRow == b.startRow &&
        (a.startCol - b.startCol).abs() == CsvWindowReader.windowCols;
  }

  void _keep(_Window window) {
    _held.removeWhere(
      (held) => held.startRow == window.startRow && held.startCol == window.startCol,
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
      focusLocalRow: focus.startRow - rowOrigin,
      focusLocalCol: focus.startCol - colOrigin,
      focusRowCount: focus.rowCount,
      focusColCount: focus.colCount,
      moreBeforeRows: upper.startRow > 0,
      moreAfterRows: lower.hasMoreRows,
      moreBeforeCols: left.startCol > 0,
      moreAfterCols: right.hasMoreCols,
      prevRow: upper.startRow - CsvWindowReader.windowRows,
      nextRow: lower.startRow + CsvWindowReader.windowRows,
      prevCol: left.startCol - CsvWindowReader.windowCols,
      nextCol: right.startCol + CsvWindowReader.windowCols,
      anchorRow: focus.startRow,
      anchorCol: focus.startCol,
    );
  }

  Future<void> _open({
    required int startRow,
    required int startCol,
    bool fromScroll = false,
    bool towardEnd = true,
    bool horizontal = false,
  }) async {
    final row = startRow < 0 ? 0 : startRow;
    final col = startCol < 0 ? 0 : startCol;
    if (fromScroll && _loading) return;
    final held = _find(row, col);
    if (held != null) {
      _show(held, fromScroll: fromScroll, towardEnd: towardEnd, horizontal: horizontal);
      return;
    }

    var byte = 0;
    var skip = row;
    if (_anchors.containsKey(row)) {
      byte = _anchors[row]!;
      skip = 0;
    } else {
      var best = -1;
      for (final key in _anchors.keys) {
        if (key <= row && key > best) best = key;
      }
      if (best >= 0) {
        byte = _anchors[best]!;
        skip = row - best;
      }
    }

    final gen = ++_gen;
    if (mounted) setState(() => _loading = true);
    try {
      final window = await CsvWindowReader.read(
        filePath: widget.filePath,
        byteOffset: byte,
        startRow: row,
        startCol: col,
        skipRecords: skip,
      );
      if (!mounted || gen != _gen) return;
      _log.i(
        'CSV sheet rows=$row cols=$col byte=$byte skip=$skip '
        'got=${window.rows.length}x'
        '${window.rows.isEmpty ? 0 : window.rows.first.length}',
      );
      if (window.rows.isEmpty && _focus != null && (row > 0 || col > 0)) {
        _stopPastEnd(row: row, col: col);
        return;
      }
      _anchors[row] = window.startByte;
      if (window.hasMoreRows) {
        _anchors[row + CsvWindowReader.windowRows] = window.endByte;
      }
      _show(
        _Window(
          startRow: row,
          startCol: col,
          startByte: window.startByte,
          hasMoreRows: window.hasMoreRows,
          hasMoreCols: window.hasMoreCols,
          rows: window.rows,
        ),
        fromScroll: fromScroll,
        towardEnd: towardEnd,
        horizontal: horizontal,
      );
    } catch (e, st) {
      _log.e('CSV window failed', error: e, stackTrace: st);
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
      (held) => held.startRow == focus.startRow && held.startCol == focus.startCol,
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
          startRow: grid.nextRow,
          startCol: grid.anchorCol,
          fromScroll: true,
          towardEnd: true,
        );
      } else if (atStart && grid.moreBeforeRows) {
        _gatedAt = now;
        _open(
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
          startRow: grid.anchorRow,
          startCol: grid.nextCol,
          fromScroll: true,
          towardEnd: true,
          horizontal: true,
        );
      } else if (atStart && grid.moreBeforeCols) {
        _gatedAt = now;
        _open(
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
                        : Center(child: Text(l10n.documentNoSheets('CSV')))
                    : grid.rows.isEmpty
                        ? Center(child: Text(l10n.sheetNoData(_sheetName)))
                        : NotificationListener<ScrollNotification>(
                            onNotification: _onGridScroll,
                            child: ProfessionalSheetViewer(
                              key: widget.sheetViewerKey,
                              sheet: SheetEntity(
                                name: _sheetName,
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
}
