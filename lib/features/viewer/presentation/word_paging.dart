import 'dart:io';

/// Caps that choose the Word reader. They match the old visual / XML / HWPF
/// limits. The import gate stays 200 MB.
abstract final class WordPaging {
  static const int visualMaxBytes = 64 * 1024 * 1024;
  static const int docxXmlMaxBytes = 12 * 1024 * 1024;
  static const int docFullParseMaxBytes = 8 * 1024 * 1024;
  static const int windowBlocks = 200;
}

/// Uncompressed size of `word/document.xml`, or -1 when it cannot be read.
/// Only the zip central directory is read.
Future<int> docxDocumentXmlBytes(String path) async {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    final length = await file.length();
    if (length < 22) return -1;
    raf = await file.open();
    final tailLen = length < 22 + 65535 ? length : 22 + 65535;
    await raf.setPosition(length - tailLen);
    final tail = await raf.read(tailLen);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tail[i] == 0x50 &&
          tail[i + 1] == 0x4B &&
          tail[i + 2] == 0x05 &&
          tail[i + 3] == 0x06) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) return -1;
    final cdSize = _u32(tail, eocd + 12);
    final cdOffset = _u32(tail, eocd + 16);
    if (cdSize == 0xFFFFFFFF || cdOffset == 0xFFFFFFFF) {
      return WordPaging.docxXmlMaxBytes + 1;
    }
    if (cdSize <= 0 || cdOffset + cdSize > length) return -1;
    if (cdSize > 8 * 1024 * 1024) return WordPaging.docxXmlMaxBytes + 1;
    await raf.setPosition(cdOffset);
    final cd = await raf.read(cdSize);
    var p = 0;
    while (p + 46 <= cd.length) {
      if (cd[p] != 0x50 ||
          cd[p + 1] != 0x4B ||
          cd[p + 2] != 0x01 ||
          cd[p + 3] != 0x02) {
        break;
      }
      final uncomp = _u32(cd, p + 24);
      final nameLen = _u16(cd, p + 28);
      final extraLen = _u16(cd, p + 30);
      final commentLen = _u16(cd, p + 32);
      final nameStart = p + 46;
      final nameEnd = nameStart + nameLen;
      if (nameEnd > cd.length) break;
      final name = String.fromCharCodes(cd.sublist(nameStart, nameEnd));
      if (name == 'word/document.xml' || name == 'Word/document.xml') {
        if (uncomp == 0xFFFFFFFF) return WordPaging.docxXmlMaxBytes + 1;
        return uncomp;
      }
      final next = nameEnd + extraLen + commentLen;
      if (next <= p) break;
      p = next;
    }
    return -1;
  } catch (_) {
    return -1;
  } finally {
    await raf?.close();
  }
}

int _u16(List<int> bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8);
}

int _u32(List<int> bytes, int offset) {
  return bytes[offset] |
      (bytes[offset + 1] << 8) |
      (bytes[offset + 2] << 16) |
      (bytes[offset + 3] << 24);
}
