import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// One bounded slice of a plain-text file.
class TxtWindow {
  final String text;
  final int startByte;
  final int endByte;
  final int fileLength;

  const TxtWindow({
    required this.text,
    required this.startByte,
    required this.endByte,
    required this.fileLength,
  });
}

/// Reads a TXT file in fixed windows so a large file is never one Dart string.
class TxtWindowReader {
  /// Bytes kept in memory for a single window (UTF-8 on disk).
  static const int windowBytes = 2 * 1024 * 1024;

  /// Safety cap so a file of blank lines cannot allocate millions of strings.
  static const int maxLines = 100000;

  static const int _snapTail = 64 * 1024;

  /// Reads forward from [byteOffset], ending on a line boundary when one sits
  /// near the end of the window.
  static Future<TxtWindow> read({
    required String filePath,
    required int byteOffset,
    int? maxBytes,
  }) async {
    final file = File(filePath);
    final length = await file.length();
    if (length == 0 || byteOffset >= length) {
      final at = byteOffset < 0
          ? 0
          : (byteOffset > length ? length : byteOffset);
      return TxtWindow(
        text: '',
        startByte: at,
        endByte: at,
        fileLength: length,
      );
    }

    final start = byteOffset < 0 ? 0 : byteOffset;
    var budget = maxBytes ?? windowBytes;
    if (budget > windowBytes) budget = windowBytes;
    if (budget < 1) budget = 1;

    var end = start + budget;
    if (end > length) end = length;
    var bytes = await _readRange(file, start, end);
    if (end < length && bytes.isNotEmpty && bytes.last == 0x0D) {
      final extra = await _readRange(file, end, end + 1);
      if (extra.isNotEmpty && extra.first == 0x0A) {
        final grown = Uint8List(bytes.length + 1);
        grown.setAll(0, bytes);
        grown[bytes.length] = 0x0A;
        bytes = grown;
        end += 1;
      }
    }

    var cut = _forwardCut(bytes, atFileEnd: end >= length);
    if (cut <= 0 && bytes.isNotEmpty) cut = 1;
    if (cut > bytes.length) cut = bytes.length;
    final text = _decode(
      Uint8List.sublistView(bytes, 0, cut),
      stripBom: start == 0,
    );
    return TxtWindow(
      text: text,
      startByte: start,
      endByte: start + cut,
      fileLength: length,
    );
  }

  /// Reads the window that ends at [endByte] (exclusive).
  static Future<TxtWindow> readBefore({
    required String filePath,
    required int endByte,
  }) async {
    final file = File(filePath);
    final length = await file.length();
    final end = endByte < 0 ? 0 : (endByte > length ? length : endByte);
    if (end == 0) {
      return TxtWindow(
        text: '',
        startByte: 0,
        endByte: 0,
        fileLength: length,
      );
    }

    var start = end - windowBytes;
    if (start < 0) start = 0;
    final bytes = await _readRange(file, start, end);
    var local = 0;
    if (start > 0) {
      local = _skipContinuation(bytes);
    }
    local = _keepLastLines(bytes, local);
    if (local >= bytes.length) local = 0;
    final text = _decode(
      Uint8List.sublistView(bytes, local),
      stripBom: start + local == 0,
    );
    return TxtWindow(
      text: text,
      startByte: start + local,
      endByte: end,
      fileLength: length,
    );
  }

  static int _forwardCut(Uint8List bytes, {required bool atFileEnd}) {
    if (bytes.isEmpty) return 0;
    var lines = 0;
    var lastNewlineEnd = -1;
    var i = 0;
    while (i < bytes.length) {
      if (_isNewlineLead(bytes, i)) {
        lines++;
        final newlineEnd = _newlineEnd(bytes, i);
        lastNewlineEnd = newlineEnd;
        if (lines >= maxLines) {
          return _utf8SafeEnd(bytes, newlineEnd);
        }
        i = newlineEnd;
        continue;
      }
      i++;
    }
    if (atFileEnd) return bytes.length;
    if (lastNewlineEnd > 0 && lastNewlineEnd >= bytes.length - _snapTail) {
      return _utf8SafeEnd(bytes, lastNewlineEnd);
    }
    return _utf8SafeEnd(bytes, bytes.length);
  }

  /// Drops whole lines from the front until at most [maxLines] remain.
  static int _keepLastLines(Uint8List bytes, int localStart) {
    var lines = 0;
    for (var i = bytes.length - 1; i >= localStart; i--) {
      if (!_isNewlineLead(bytes, i)) continue;
      lines++;
      if (lines > maxLines) {
        final next = _newlineEnd(bytes, i);
        if (next < bytes.length) return next;
        return localStart;
      }
    }
    return localStart;
  }

  static bool _isNewlineLead(Uint8List bytes, int index) {
    final byte = bytes[index];
    if (byte == 0x0A) {
      return index == 0 || bytes[index - 1] != 0x0D;
    }
    return byte == 0x0D;
  }

  static int _newlineEnd(Uint8List bytes, int index) {
    if (bytes[index] == 0x0D &&
        index + 1 < bytes.length &&
        bytes[index + 1] == 0x0A) {
      return index + 2;
    }
    return index + 1;
  }

  static int _skipContinuation(Uint8List bytes) {
    var i = 0;
    while (i < bytes.length && i < 3 && (bytes[i] & 0xC0) == 0x80) {
      i++;
    }
    if (i >= bytes.length) return 0;
    return i;
  }

  static int _utf8SafeEnd(Uint8List bytes, int end) {
    if (end <= 0) return 0;
    if (end > bytes.length) end = bytes.length;
    var i = end - 1;
    var continuations = 0;
    while (i > 0 && continuations < 3 && (bytes[i] & 0xC0) == 0x80) {
      i--;
      continuations++;
    }
    if (i < 0) return end;
    final lead = bytes[i];
    final need = (lead & 0x80) == 0
        ? 1
        : (lead & 0xE0) == 0xC0
            ? 2
            : (lead & 0xF0) == 0xE0
                ? 3
                : (lead & 0xF8) == 0xF0
                    ? 4
                    : 1;
    if (i + need > end) return i > 0 ? i : end;
    return end;
  }

  static String _decode(Uint8List bytes, {required bool stripBom}) {
    if (bytes.isEmpty) return '';
    var text = utf8.decode(bytes, allowMalformed: true);
    if (stripBom && text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
      text = text.substring(1);
    }
    if (text.contains('\r')) {
      text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    }
    return text;
  }

  static Future<Uint8List> _readRange(File file, int start, int end) async {
    if (end <= start) return Uint8List(0);
    final builder = BytesBuilder(copy: false);
    await for (final chunk in file.openRead(start, end)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }
}
