package com.airdocsviewer

/**
 * Maps Word Symbol / Wingdings / Private Use Area glyphs to portable Unicode.
 * Same rules as Dart [OfficeGlyphSanitizer].
 */
object OfficeGlyphSanitizer {
    private val bulletMap = mapOf(
        0xF0B7 to 0x2022,
        0xF06C to 0x2022,
        0xF075 to 0x2022,
        0xF0BE to 0x2022,
        0xF0B0 to 0x2022,
        0xF0A7 to 0x25AA,
        0xF09F to 0x25AA,
        0xF0B2 to 0x25A0,
        0xF0A8 to 0x25CB,
        0xF0D8 to 0x25B6,
        0xF0AE to 0x25B6,
        0xF0FC to 0x2713,
        0xF02D to 0x2013,
        0x00B7 to 0x2022,
    )

    fun sanitize(input: String?): String {
        if (input.isNullOrEmpty()) return input.orEmpty()
        val out = StringBuilder(input.length)
        var i = 0
        while (i < input.length) {
            val cp = Character.codePointAt(input, i)
            val mapped = bulletMap[cp]
            when {
                mapped != null -> out.appendCodePoint(mapped)
                cp in 0xF000..0xF0FF -> out.appendCodePoint(0x2022)
                cp == 0xFFFE || cp == 0xFFFF -> Unit
                else -> out.appendCodePoint(cp)
            }
            i += Character.charCount(cp)
        }
        return out.toString()
    }

    fun isSymbolFont(fontFamily: String?): Boolean {
        if (fontFamily.isNullOrBlank()) return false
        val lower = fontFamily.lowercase()
        return lower.contains("symbol") ||
            lower.contains("wingdings") ||
            lower.contains("webdings")
    }
}
