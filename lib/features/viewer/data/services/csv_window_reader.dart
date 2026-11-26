import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:logger/logger.dart';

/// One rectangle of a CSV file.
///
/// [startByte] is the first byte of the first record in this window.
/// [endByte] is the first byte of the following record, or the file length.
class CsvWindow {
  const CsvWindow({
    required this.rows,
    required this.startRow,
    required this.startCol,
    required this.startByte,
    required this.endByte,
    required this.fileLength,
    required this.hasMoreRows,
    required this.hasMoreCols,
  });

  final List<List<String>> rows;
  final int startRow;
  final int startCol;
  final int startByte;
  final int endByte;
  final int fileLength;
  final bool hasMoreRows;
  final bool hasMoreCols;
}

/// Streams CSV records from a byte offset.
///
/// [byteOffset] must be `0` or a record boundary returned as [CsvWindow.endByte].
/// [skipRecords] discards that many whole records first, still from a boundary,
/// so a later window does not start inside a quoted field.
class CsvWindowReader {
  CsvWindowReader._();

  static final _log = Logger();

  /// Same rectangle the Excel pager uses.
  static const int windowRows = 200;
  static const int windowCols = 30;

  /// Stored characters per cell. Later fields and rows are still parsed.
  static const int maxCellChars = 2048;

  static const int _chunk = 64 * 1024;

  static Future<CsvWindow> read({
    required String filePath,
    required int byteOffset,
    required int startRow,
    int startCol = 0,
    int? rowCount,
    int? colCount,
    int skipRecords = 0,
  }) async {
    final file = File(filePath);
    final length = await file.length();
    final row = startRow < 0 ? 0 : startRow;
    final col = startCol < 0 ? 0 : startCol;
    var rowsWanted = rowCount ?? windowRows;
    var colsWanted = colCount ?? windowCols;
    if (rowsWanted > windowRows) rowsWanted = windowRows;
    if (rowsWanted < 1) rowsWanted = 1;
    if (colsWanted > windowCols) colsWanted = windowCols;
    if (colsWanted < 1) colsWanted = 1;
    final skip = skipRecords < 0 ? 0 : skipRecords;
    var start = byteOffset;
    if (start < 0) start = 0;
    if (start > length) start = length;

    if (length == 0 || start >= length) {
      return CsvWindow(
        rows: const [],
        startRow: row,
        startCol: col,
        startByte: start,
        endByte: start,
        fileLength: length,
        hasMoreRows: false,
        hasMoreCols: false,
      );
    }

    final raf = await file.open();
    try {
      final parser = _Parser(
        raf: raf,
        length: length,
        start: start,
        startRow: row,
        startCol: col,
        rowCount: rowsWanted,
        colCount: colsWanted,
        skipRecords: skip,
      );
      final window = await parser.run();
      _log.i(
        'CSV window row=$row col=$col bytes=${window.startByte}-${window.endByte} '
        'got=${window.rows.length}x'
        '${window.rows.isEmpty ? 0 : window.rows.first.length} '
        'moreRows=${window.hasMoreRows} moreCols=${window.hasMoreCols}',
      );
      return window;
    } finally {
      await raf.close();
    }
  }
}

class _Source {
  _Source(this.raf, this.length);

  final RandomAccessFile raf;
  final int length;
  int pos = 0;
  int _base = 0;
  Uint8List _buf = Uint8List(0);

  int get bufferedEnd => _base + _buf.length;

  Future<void> jump(int offset) async {
    pos = offset;
    _base = offset;
    _buf = Uint8List(0);
    await raf.setPosition(offset);
  }

  bool has(int absEnd) => absEnd <= bufferedEnd && absEnd >= _base;

  int at(int abs) => _buf[abs - _base];

  Uint8List slice(int from, int to) {
    return Uint8List.sublistView(_buf, from - _base, to - _base);
  }

  /// Reads the next chunk. Drops bytes already parsed so a long record
  /// does not stay in memory.
  Future<bool> fill() async {
    if (pos > _base) {
      final drop = pos - _base;
      if (drop >= _buf.length) {
        _buf = Uint8List(0);
      } else {
        _buf = Uint8List.fromList(_buf.sublist(drop));
      }
      _base = pos;
    }
    if (bufferedEnd >= length) return false;
    final n = min(CsvWindowReader._chunk, length - bufferedEnd);
    final chunk = await raf.read(n);
    if (chunk.isEmpty) return false;
    final merged = Uint8List(_buf.length + chunk.length);
    merged.setRange(0, _buf.length, _buf);
    merged.setRange(_buf.length, merged.length, chunk);
    _buf = merged;
    return true;
  }
}

class _Parser {
  _Parser({
    required RandomAccessFile raf,
    required this.length,
    required this.start,
    required this.startRow,
    required this.startCol,
    required this.rowCount,
    required this.colCount,
    required this.skipRecords,
  }) : src = _Source(raf, length);

  final _Source src;
  final int length;
  final int start;
  final int startRow;
  final int startCol;
  final int rowCount;
  final int colCount;
  int skipRecords;

  final List<List<String>> _rows = [];
  final StringBuffer _cell = StringBuffer();
  List<String> _current = [];
  int _cellChars = 0;
  int _fieldIndex = 0;
  int _recordStart = 0;
  int _windowStart = 0;
  int _kept = 0;
  bool _inQuotes = false;
  bool _started = false;
  bool _storedCell = false;
  bool _moreCols = false;

  Future<CsvWindow> run() async {
    await src.jump(start);
    if (start == 0) await _skipBom();
    _recordStart = src.pos;
    _windowStart = src.pos;

    while (true) {
      if (skipRecords == 0 && _rows.length >= rowCount) break;
      if (src.pos >= length) {
        _eof();
        break;
      }
      if (src.pos >= src.bufferedEnd) {
        final grew = await src.fill();
        if (!grew) {
          _eof();
          break;
        }
        continue;
      }
      final lead = src.at(src.pos);
      if (_needsMore(lead)) {
        final endBefore = src.bufferedEnd;
        final grew = await src.fill();
        if (grew && src.bufferedEnd > endBefore) continue;
      }
      _accept(lead);
    }

    final hasMoreRows = _kept >= rowCount && src.pos < length;
    if (startCol > 0 && !_storedCell) {
      _rows.clear();
    }
    var width = 0;
    for (final row in _rows) {
      if (row.length > width) width = row.length;
    }
    for (final row in _rows) {
      while (row.length < width) {
        row.add('');
      }
    }

    return CsvWindow(
      rows: _rows,
      startRow: startRow,
      startCol: startCol,
      startByte: _windowStart,
      endByte: src.pos,
      fileLength: length,
      hasMoreRows: hasMoreRows,
      hasMoreCols: _moreCols,
    );
  }

  Future<void> _skipBom() async {
    if (length < 3) return;
    await src.fill();
    if (src.bufferedEnd >= 3 &&
        src.at(0) == 0xEF &&
        src.at(1) == 0xBB &&
        src.at(2) == 0xBF) {
      src.pos = 3;
    }
  }

  bool _needsMore(int lead) {
    var want = 1;
    if (lead == 0x22 || (!_inQuotes && lead == 0x0D)) {
      want = 2;
    } else if (lead >= 0x80) {
      want = _utf8Len(lead);
    }
    final end = src.pos + want;
    if (end > length) return false;
    return !src.has(end);
  }

  int _utf8Len(int lead) {
    if (lead >= 0xC2 && lead <= 0xDF) return 2;
    if (lead >= 0xE0 && lead <= 0xEF) return 3;
    if (lead >= 0xF0 && lead <= 0xF4) return 4;
    return 1;
  }

  void _accept(int lead) {
    if (lead == 0x22) {
      final paired = _inQuotes &&
          src.pos + 1 < length &&
          src.has(src.pos + 2) &&
          src.at(src.pos + 1) == 0x22;
      if (paired) {
        src.pos += 2;
        _addChar('"');
      } else {
        src.pos += 1;
        _started = true;
        _inQuotes = !_inQuotes;
      }
      return;
    }
    if (!_inQuotes && lead == 0x2C) {
      src.pos += 1;
      _started = true;
      _endField();
      return;
    }
    if (!_inQuotes && (lead == 0x0A || lead == 0x0D)) {
      if (lead == 0x0D &&
          src.pos + 1 < length &&
          src.has(src.pos + 2) &&
          src.at(src.pos + 1) == 0x0A) {
        src.pos += 2;
      } else {
        src.pos += 1;
      }
      _endRecord();
      return;
    }
    _takeText(lead);
  }

  void _takeText(int lead) {
    if (lead < 0x80) {
      src.pos += 1;
      _addChar(String.fromCharCode(lead));
      return;
    }
    final n = _utf8Len(lead);
    final available = length - src.pos;
    if (n == 1 || n > available || !src.has(src.pos + n) || !_valid(n)) {
      src.pos += 1;
      _addChar('\uFFFD');
      return;
    }
    final bytes = src.slice(src.pos, src.pos + n);
    src.pos += n;
    _addChar(utf8.decode(bytes, allowMalformed: true));
  }

  bool _valid(int n) {
    for (var i = 1; i < n; i++) {
      if ((src.at(src.pos + i) & 0xC0) != 0x80) return false;
    }
    final lead = src.at(src.pos);
    if (n == 2) return lead >= 0xC2;
    if (n == 3) return lead >= 0xE0;
    if (n == 4) return lead >= 0xF0;
    return false;
  }

  void _addChar(String ch) {
    _started = true;
    if (_cellChars >= CsvWindowReader.maxCellChars) return;
    _cell.write(ch);
    _cellChars++;
  }

  void _endField() {
    final index = _fieldIndex;
    final text = _cell.toString();
    _fieldIndex++;
    _cell.clear();
    _cellChars = 0;
    if (skipRecords > 0) return;
    if (index >= startCol + colCount) {
      _moreCols = true;
      return;
    }
    if (index < startCol) return;
    _current.add(text);
    _storedCell = true;
  }

  void _endRecord() {
    final startedAt = _recordStart;
    _endField();
    final row = List<String>.from(_current);
    _resetRecord();
    _recordStart = src.pos;
    if (skipRecords > 0) {
      skipRecords--;
      return;
    }
    if (_rows.isEmpty) _windowStart = startedAt;
    _rows.add(row);
    _kept++;
  }

  void _resetRecord() {
    _cell.clear();
    _cellChars = 0;
    _fieldIndex = 0;
    _current = [];
    _started = false;
    _inQuotes = false;
  }

  void _eof() {
    if (!_started && !_inQuotes) return;
    _endRecord();
  }
}
