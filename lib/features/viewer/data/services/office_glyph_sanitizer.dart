/// Maps Word Symbol / Wingdings / Private Use Area glyphs to portable Unicode.
///
/// Office apps often store bullets as Symbol-font code points (e.g. U+F0B7).
/// Those fonts are usually missing on Android, so characters show as tofu boxes.
class OfficeGlyphSanitizer {
  OfficeGlyphSanitizer._();

  static const Map<int, int> _bulletMap = {
    0xF0B7: 0x2022, // •
    0xF06C: 0x2022,
    0xF075: 0x2022,
    0xF0BE: 0x2022,
    0xF0B0: 0x2022,
    0xF0A7: 0x25AA, // ▪
    0xF09F: 0x25AA,
    0xF0B2: 0x25A0, // ■
    0xF0A8: 0x25CB, // ○
    0xF0D8: 0x25B6, // ▶
    0xF0AE: 0x25B6,
    0xF0FC: 0x2713, // ✓
    0xF02D: 0x2013, // –
    0x00B7: 0x2022,
  };

  /// Replace Symbol/Wingdings/PUA glyphs with Unicode equivalents.
  static String sanitize(String? input) {
    if (input == null || input.isEmpty) return input ?? '';
    final buffer = StringBuffer();
    for (final unit in input.runes) {
      final mapped = _bulletMap[unit];
      if (mapped != null) {
        buffer.writeCharCode(mapped);
      } else if (unit >= 0xF000 && unit <= 0xF0FF) {
        // Remaining Symbol private-use range → generic bullet.
        buffer.writeCharCode(0x2022);
      } else if (unit == 0xFFFE || unit == 0xFFFF || (unit >= 0xD800 && unit <= 0xDFFF)) {
        // Skip invalid / unpaired surrogates.
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }

  /// True when [fontFamily] is a known non-portable Office symbol font.
  static bool isSymbolFont(String? fontFamily) {
    if (fontFamily == null || fontFamily.isEmpty) return false;
    final lower = fontFamily.toLowerCase();
    return lower.contains('symbol') ||
        lower.contains('wingdings') ||
        lower.contains('webdings');
  }

  /// Strip a leading bullet glyph (after sanitize) — useful when a list marker
  /// is already synthesized separately.
  static String stripLeadingBullet(String text) {
    return text.replaceFirst(
      RegExp(
        r'^[\s\uF000-\uF0FF\u2022\u25CF\u25AA\u25A0\u25CB\u25B6\u00B7•◦▪‣\-–—*]+',
      ),
      '',
    );
  }
}
