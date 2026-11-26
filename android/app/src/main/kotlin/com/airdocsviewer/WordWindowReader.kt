package com.airdocsviewer

import android.util.Log
import org.apache.poi.poifs.filesystem.DirectoryNode
import org.apache.poi.poifs.filesystem.DocumentEntry
import org.apache.poi.poifs.filesystem.DocumentInputStream
import org.apache.poi.poifs.filesystem.POIFSFileSystem
import java.io.BufferedReader
import java.io.Closeable
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.nio.charset.Charset
import java.nio.charset.StandardCharsets
import java.util.zip.ZipFile

/**
 * One window of Word text. Does not build [org.apache.poi.xwpf.usermodel.XWPFDocument]
 * or [org.apache.poi.hwpf.HWPFDocument], and does not read `word/media`.
 *
 * A window is [windowBlocks] paragraphs. The caller drops every window except
 * the one on screen and one neighbor.
 */
internal class WordWindowReader(private val tag: String) {

    fun read(file: File, format: String, start: Int): Map<String, Any> {
        val safeStart = start.coerceAtLeast(0)
        return try {
            when (format.uppercase()) {
                "DOCX" -> readDocx(file, safeStart)
                "DOC" -> readDoc(file, safeStart)
                else -> failed(safeStart, hasMore = false)
            }
        } catch (t: Throwable) {
            Log.e(tag, "readWordWindow ${format.uppercase()} start=$safeStart", t)
            failed(safeStart, hasMore = true)
        }
    }

    private fun readDocx(file: File, start: Int): Map<String, Any> {
        return try {
            readDocxZip(file, start)
        } catch (t: Throwable) {
            if (looksLikeOle(file)) {
                Log.w(tag, "DOCX package is OLE; streaming the WordDocument stream")
                readDoc(file, start)
            } else {
                throw t
            }
        }
    }

    private fun readDocxZip(file: File, start: Int): Map<String, Any> {
        ZipFile(file).use { zip ->
            val entry = findDocumentXml(zip)
            if (entry == null) {
                Log.i(tag, "readWordWindow DOCX no document.xml")
                return result(start, emptyList(), hasMore = false)
            }
            zip.getInputStream(entry).use { raw ->
                val scan = DocxParagraphWindow(start, windowBlocks)
                scan.read(raw)
                Log.i(
                    tag,
                    "readWordWindow DOCX start=$start blocks=${scan.blocks.size} " +
                        "hasMore=${scan.hasMore} xmlBytes=${entry.size}",
                )
                return result(start, scan.blocks, scan.hasMore)
            }
        }
    }

    /**
     * Binary .doc. The piece table (or, when there is none, the contiguous
     * range at fcMin) is read in [chunkBytes] chunks. Picture bytes in other
     * OLE streams are never opened.
     */
    private fun readDoc(file: File, start: Int): Map<String, Any> {
        val fs = POIFSFileSystem(file, true)
        try {
            val root = fs.root
            if (!root.hasEntry("WordDocument")) {
                Log.w(tag, "DOC has no WordDocument stream")
                return failed(start, hasMore = false)
            }
            val wordEntry = root.getEntry("WordDocument")
            val wordSize = if (wordEntry is DocumentEntry) wordEntry.size.toLong() else 0L
            if (wordSize < 32L) {
                return failed(start, hasMore = false)
            }
            OleCursor(root, "WordDocument").use { word ->
                val headLen = minOf(wordSize, 65_536L).toInt()
                val head = word.readAt(0L, headLen)
                val fib = Fib.parse(head) ?: run {
                    Log.w(tag, "DOC FIB could not be read")
                    return failed(start, hasMore = false)
                }
                if (fib.encrypted || fib.obfuscated) {
                    Log.w(tag, "DOC encryption flag set; text is not read")
                    return failed(start, hasMore = false)
                }
                val state = DocParagraphWindow(start, windowBlocks)
                val tableName = chooseTable(root, fib)
                val clx = if (tableName != null) locateClx(root, tableName, fib) else null
                if (tableName != null && clx != null && clx.pieceCount > 0L) {
                    Log.i(
                        tag,
                        "DOC streaming piece table pieces=${clx.pieceCount} " +
                            "ccpText=${fib.ccpText} without HWPFDocument",
                    )
                    streamPieces(root, tableName, word, clx, fib.ccpText, state)
                } else {
                    val span = fib.fcMac - fib.fcMin
                    Log.i(
                        tag,
                        "DOC streaming contiguous text fcMin=${fib.fcMin} " +
                            "bytes=$span without HWPFDocument",
                    )
                    if (span > 0L) {
                        streamRange(word, fib.fcMin, span, fib.contiguousUnicode(span), state)
                    }
                }
                state.finish()
                Log.i(
                    tag,
                    "readWordWindow DOC start=$start blocks=${state.blocks.size} " +
                        "hasMore=${state.hasMore}",
                )
                return result(start, state.blocks, state.hasMore)
            }
        } finally {
            fs.close()
        }
    }

    private fun streamPieces(
        root: DirectoryNode,
        tableName: String,
        word: OleCursor,
        clx: ClxLocation,
        ccpText: Int,
        state: DocParagraphWindow,
    ) {
        OleCursor(root, tableName).use { cps ->
            OleCursor(root, tableName).use { pcds ->
                var index = 0L
                while (index < clx.pieceCount && !state.stop) {
                    val batch = minOf(512L, clx.pieceCount - index).toInt()
                    val cpBytes = cps.readAt(clx.cpOffset + index * 4L, (batch + 1) * 4)
                    val pcdBytes = pcds.readAt(clx.pcdOffset + index * 8L, batch * 8)
                    for (i in 0 until batch) {
                        if (state.stop) return
                        val cp0 = i32(cpBytes, i * 4)
                        val cp1 = i32(cpBytes, (i + 1) * 4)
                        if (ccpText > 0 && cp0 >= ccpText) return
                        var end = cp1
                        if (ccpText > 0 && end > ccpText) end = ccpText
                        val chars = end.toLong() - cp0.toLong()
                        if (chars <= 0L) continue
                        val pcdOff = i * 8
                        val fcRaw = i32(pcdBytes, pcdOff + 2)
                        val unicode = (fcRaw and 0x40000000) == 0
                        val fc = if (unicode) {
                            fcRaw.toLong() and 0xFFFFFFFFL
                        } else {
                            (fcRaw and 0x3FFFFFFF).toLong() / 2L
                        }
                        val byteLen = if (unicode) chars * 2L else chars
                        try {
                            streamRange(word, fc, byteLen, unicode, state)
                        } catch (t: Exception) {
                            Log.w(tag, "DOC skipped a text piece at $fc ($byteLen bytes): ${t.message}")
                            state.skipPiece()
                        }
                    }
                    index += batch
                }
            }
        }
    }

    private fun streamRange(
        word: OleCursor,
        offset: Long,
        byteLen: Long,
        unicode: Boolean,
        state: DocParagraphWindow,
    ) {
        var left = byteLen
        var pos = offset
        while (left > 0L && !state.stop) {
            var take = minOf(left, chunkBytes.toLong()).toInt()
            if (unicode && take % 2 != 0) take -= 1
            if (take <= 0) return
            val bytes = word.readAt(pos, take)
            pos += take
            left -= take
            val text = if (unicode) {
                String(bytes, StandardCharsets.UTF_16LE)
            } else {
                String(bytes, cp1252)
            }
            state.consume(text)
        }
    }

    private fun locateClx(root: DirectoryNode, tableName: String, fib: Fib): ClxLocation? {
        if (fib.fcClx < 0L || fib.lcbClx < 5L) return null
        val entry = root.getEntry(tableName)
        val tableSize = if (entry is DocumentEntry) entry.size.toLong() else return null
        OleCursor(root, tableName).use { table ->
            var off = fib.fcClx
            val end = minOf(tableSize, fib.fcClx + fib.lcbClx)
            var guard = 0
            while (off + 1 < end && guard < 64) {
                guard += 1
                val kind = table.readAt(off, 1)[0].toInt() and 0xFF
                if (kind == 0x02) {
                    if (off + 5 > end) return null
                    val lcb = u32(table.readAt(off + 1, 4), 0)
                    if (lcb < 16L) return null
                    val payload = off + 5
                    val pieces = (lcb - 4L) / 12L
                    if (pieces <= 0L) return null
                    return ClxLocation(
                        cpOffset = payload,
                        pcdOffset = payload + (pieces + 1L) * 4L,
                        pieceCount = pieces,
                    )
                }
                if (kind == 0x01) {
                    if (off + 3 > end) return null
                    val cb = u16(table.readAt(off + 1, 2), 0)
                    off += 3L + cb
                    continue
                }
                return null
            }
        }
        return null
    }

    private class ClxLocation(
        val cpOffset: Long,
        val pcdOffset: Long,
        val pieceCount: Long,
    )

    /**
     * FibBase plus the Word 97 fc/lcb pair for the CLX. Later Word versions
     * append pairs; pair 31 stays the piece table (MS-DOC FibRgFcLcb97).
     */
    private class Fib(
        val encrypted: Boolean,
        val obfuscated: Boolean,
        val whichTable: Boolean,
        val extChar: Boolean,
        val fcMin: Long,
        val fcMac: Long,
        val ccpText: Int,
        val fcClx: Long,
        val lcbClx: Long,
    ) {
        fun tableName(): String = if (whichTable) "1Table" else "0Table"

        /** Byte length matches the character count, otherwise trust fExtChar. */
        fun contiguousUnicode(span: Long): Boolean {
            if (ccpText > 0 && span == ccpText.toLong()) return false
            if (ccpText > 0 && span == ccpText.toLong() * 2L) return true
            return extChar
        }

        companion object {
            fun parse(head: ByteArray): Fib? {
                if (head.size < 32 || u16(head, 0) != 0xA5EC) return null
                val flags = u16(head, 10)
                val rgLw = rgLwOffset(head)
                val ccpText = if (rgLw >= 0 && rgLw + 16 <= head.size) {
                    i32(head, rgLw + 12).coerceAtLeast(0)
                } else {
                    0
                }
                val clx = clxPair(head)
                return Fib(
                    encrypted = flags and 0x0100 != 0,
                    obfuscated = flags and 0x8000 != 0,
                    whichTable = flags and 0x0200 != 0,
                    extChar = flags and 0x1000 != 0,
                    fcMin = u32(head, 24),
                    fcMac = u32(head, 28),
                    ccpText = ccpText,
                    fcClx = clx.first,
                    lcbClx = clx.second,
                )
            }

            private fun rgLwOffset(head: ByteArray): Int {
                if (head.size < 34) return -1
                val csw = u16(head, 32)
                val cslwAt = 34 + csw * 2
                if (cslwAt + 2 > head.size) return -1
                return cslwAt + 2
            }

            private fun clxPair(head: ByteArray): Pair<Long, Long> {
                val rgLw = rgLwOffset(head)
                if (rgLw < 0) return -1L to 0L
                val cslw = u16(head, rgLw - 2)
                val pairsAt = rgLw + cslw * 4
                if (pairsAt + 2 > head.size) return -1L to 0L
                val count = u16(head, pairsAt)
                if (count <= CLX_INDEX) return -1L to 0L
                val at = pairsAt + 2 + CLX_INDEX * 8
                if (at + 8 > head.size) return -1L to 0L
                return u32(head, at) to u32(head, at + 4)
            }
        }
    }

    private class OleCursor(
        private val root: DirectoryNode,
        private val entry: String,
    ) : Closeable {
        private var stream: DocumentInputStream? = null
        private var pos = 0L

        fun readAt(offset: Long, length: Int): ByteArray {
            if (length <= 0) return ByteArray(0)
            if (offset < 0L) throw IOException("bad offset")
            val input = reposition(offset)
            val buf = ByteArray(length)
            var off = 0
            while (off < length) {
                val n = input.read(buf, off, length - off)
                if (n < 0) throw IOException("short read")
                off += n
            }
            pos = offset + length
            return buf
        }

        private fun reposition(offset: Long): DocumentInputStream {
            val current = stream
            val input = if (current == null || offset < pos) {
                current?.close()
                val opened = root.createDocumentInputStream(entry)
                stream = opened
                pos = 0L
                opened
            } else {
                current
            }
            if (offset > pos) {
                if (!discard(input, offset - pos)) throw IOException("short skip")
                pos = offset
            }
            return input
        }

        override fun close() {
            stream?.close()
            stream = null
        }
    }

    private fun chooseTable(root: DirectoryNode, fib: Fib): String? {
        val preferred = fib.tableName()
        if (root.hasEntry(preferred)) return preferred
        val other = if (preferred == "1Table") "0Table" else "1Table"
        return if (root.hasEntry(other)) other else null
    }

    private fun findDocumentXml(zip: ZipFile): java.util.zip.ZipEntry? {
        zip.getEntry("word/document.xml")?.let { return it }
        val entries = zip.entries()
        while (entries.hasMoreElements()) {
            val entry = entries.nextElement()
            val name = entry.name.replace('\\', '/')
            if (name.equals("word/document.xml", ignoreCase = true)) return entry
        }
        return null
    }

    private class DocxParagraphWindow(
        private val start: Int,
        private val limit: Int,
    ) {
        val blocks = mutableListOf<Map<String, Any>>()
        var hasMore = false
        private var stop = false
        private val stack = ArrayDeque<Frame>()
        private var overflow = 0
        private var inText = 0
        private var nextIndex = 0

        fun read(input: InputStream) {
            val reader = BufferedReader(InputStreamReader(input, StandardCharsets.UTF_8), 8192)
            var inTag = false
            val tag = StringBuilder()
            var entity: StringBuilder? = null
            while (!stop) {
                val value = reader.read()
                if (value < 0) break
                val ch = value.toChar()
                val pending = entity
                if (pending != null) {
                    if (ch == ';') {
                        appendText(decodeEntity(pending.toString()))
                        entity = null
                    } else if (pending.length >= 12 || ch == '<' || ch == '&') {
                        appendText("&")
                        appendText(pending.toString())
                        entity = null
                        if (ch == '<') {
                            inTag = beginTag(reader, tag)
                        } else if (ch != '&') {
                            appendText(ch.toString())
                        } else {
                            entity = StringBuilder()
                        }
                    } else {
                        pending.append(ch)
                    }
                    continue
                }
                if (inTag) {
                    if (ch == '>') {
                        inTag = false
                        onTag(tag.toString())
                        tag.setLength(0)
                    } else if (tag.length < 512) {
                        tag.append(ch)
                    }
                    continue
                }
                if (ch == '<') {
                    inTag = beginTag(reader, tag)
                    continue
                }
                if (ch == '&' && inText > 0 && stack.isNotEmpty()) {
                    entity = StringBuilder()
                    continue
                }
                if (inText > 0) appendText(ch.toString())
            }
        }

        private fun beginTag(reader: BufferedReader, tag: StringBuilder): Boolean {
            reader.mark(16)
            val n1 = reader.read()
            if (n1 == '!'.code) {
                val n2 = reader.read()
                val n3 = reader.read()
                if (n2 == '-'.code && n3 == '-'.code) {
                    skipUntil(reader, "-->")
                    return false
                }
                if (n2 == '['.code && n3 == 'C'.code) {
                    skipUntil(reader, "]]>")
                    return false
                }
            } else if (n1 == '?'.code) {
                skipUntil(reader, "?>")
                return false
            }
            reader.reset()
            tag.setLength(0)
            return true
        }

        private fun onTag(raw: String) {
            val closing = raw.startsWith("/")
            val selfClose = raw.endsWith("/")
            var body = raw.trim()
            if (closing && body.isNotEmpty()) body = body.substring(1)
            if (selfClose && body.endsWith("/")) body = body.substring(0, body.length - 1).trim()
            val nameEnd = body.indexOfFirst { it.isWhitespace() }
            val name = if (nameEnd < 0) body else body.substring(0, nameEnd)
            val prefix = name.substringBefore(':', "")
            val local = name.substringAfter(':')
            // DrawingML uses a:t. Only the wordprocessingml text nodes are paragraphs.
            if (prefix.isNotEmpty() && prefix != "w") return
            if (closing) {
                when (local) {
                    "p" -> endParagraph()
                    "t" -> if (inText > 0) inText -= 1
                }
                return
            }
            when (local) {
                "p" -> if (!selfClose) startParagraph()
                "t" -> if (!selfClose && stack.isNotEmpty()) inText += 1
                "tab" -> appendPlain("\t")
                "br", "cr" -> appendPlain("\n")
            }
        }

        private fun appendPlain(text: String) {
            if (stack.isEmpty() || stop) return
            val saved = inText
            inText = 1
            appendText(text)
            inText = saved
        }

        private fun startParagraph() {
            if (stack.size >= 32) {
                overflow += 1
                return
            }
            stack.addLast(Frame())
        }

        private fun endParagraph() {
            if (overflow > 0) {
                overflow -= 1
                return
            }
            if (stack.isEmpty()) return
            val frame = stack.removeLast()
            val text = if (frame.skipped) {
                ""
            } else {
                OfficeGlyphSanitizer.sanitize(frame.buf.toString()).trim()
            }
            if (!frame.skipped && text.isEmpty()) return
            val idx = nextIndex++
            if (idx >= start + limit) {
                hasMore = true
                stop = true
                return
            }
            if (idx >= start) {
                blocks.add(mapOf("text" to text, "skipped" to frame.skipped))
            }
        }

        private fun appendText(text: String) {
            if (text.isEmpty() || inText <= 0 || stack.isEmpty() || stop) return
            val frame = stack.last()
            if (frame.skipped) return
            for (ch in text) {
                if (frame.buf.length >= maxParagraphChars) {
                    frame.skipped = true
                    frame.buf.setLength(0)
                    return
                }
                frame.buf.append(ch)
            }
        }
    }

    private class Frame {
        val buf = StringBuilder()
        var skipped = false
    }

    private class DocParagraphWindow(
        private val start: Int,
        private val limit: Int,
    ) {
        val blocks = mutableListOf<Map<String, Any>>()
        var hasMore = false
        var stop = false
        private var nextIndex = 0
        private val buf = StringBuilder()
        private var skipped = false

        fun consume(text: String) {
            for (ch in text) {
                if (stop) return
                when (ch) {
                    '\r', '\u0007', '\u000c' -> emit()
                    '\n', '\u000b' -> append('\n')
                    '\t' -> append('\t')
                    else -> if (ch.code >= 0x20) append(ch)
                }
            }
        }

        fun finish() {
            if (!stop && (buf.isNotEmpty() || skipped)) emit()
        }

        fun skipPiece() {
            if (stop) return
            buf.setLength(0)
            skipped = true
            emit()
        }

        private fun append(ch: Char) {
            if (stop || skipped) return
            if (buf.length >= maxParagraphChars) {
                skipped = true
                buf.setLength(0)
                return
            }
            buf.append(ch)
        }

        private fun emit() {
            if (stop) return
            val text = if (skipped) {
                ""
            } else {
                OfficeGlyphSanitizer.sanitize(buf.toString()).trim()
            }
            val wasSkipped = skipped
            buf.setLength(0)
            skipped = false
            if (!wasSkipped && text.isEmpty()) return
            val idx = nextIndex++
            if (idx >= start + limit) {
                hasMore = true
                stop = true
                return
            }
            if (idx >= start) {
                blocks.add(mapOf("text" to text, "skipped" to wasSkipped))
            }
        }
    }

    private fun looksLikeOle(file: File): Boolean {
        return try {
            FileInputStream(file).use { input ->
                val magic = ByteArray(8)
                val n = input.read(magic)
                n >= 4 &&
                    magic[0] == 0xD0.toByte() &&
                    magic[1] == 0xCF.toByte() &&
                    magic[2] == 0x11.toByte() &&
                    magic[3] == 0xE0.toByte()
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun failed(start: Int, hasMore: Boolean): Map<String, Any> {
        return result(start, emptyList(), hasMore, failed = true)
    }

    private fun result(
        start: Int,
        blocks: List<Map<String, Any>>,
        hasMore: Boolean,
        failed: Boolean = false,
    ): Map<String, Any> {
        return mapOf(
            "start" to start,
            "blocks" to blocks,
            "hasMore" to hasMore,
            "failed" to failed,
        )
    }

    companion object {
        const val windowBlocks = 200
        private const val maxParagraphChars = 16_384
        private const val chunkBytes = 32 * 1024
        private const val CLX_INDEX = 31
        private val cp1252: Charset = try {
            Charset.forName("windows-1252")
        } catch (_: Exception) {
            StandardCharsets.ISO_8859_1
        }

        private fun decodeEntity(body: String): String {
            when (body) {
                "amp" -> return "&"
                "lt" -> return "<"
                "gt" -> return ">"
                "quot" -> return "\""
                "apos" -> return "'"
            }
            val code = when {
                body.startsWith("#x") || body.startsWith("#X") -> body.substring(2).toIntOrNull(16)
                body.startsWith("#") -> body.substring(1).toIntOrNull()
                else -> null
            } ?: return ""
            if (code <= 0 || code > 0x10FFFF) return ""
            return String(Character.toChars(code))
        }

        private fun skipUntil(reader: BufferedReader, token: String) {
            val needle = token.toCharArray()
            var matched = 0
            while (matched < needle.size) {
                val value = reader.read()
                if (value < 0) return
                val ch = value.toChar()
                matched = when {
                    ch == needle[matched] -> matched + 1
                    ch == needle[0] -> 1
                    else -> 0
                }
            }
        }

        private fun discard(input: InputStream, bytes: Long): Boolean {
            var left = bytes
            val scratch = ByteArray(8192)
            while (left > 0L) {
                val n = input.read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
                if (n <= 0) return false
                left -= n
            }
            return true
        }

        fun u16(b: ByteArray, off: Int): Int {
            return (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
        }

        fun u32(b: ByteArray, off: Int): Long {
            return (b[off].toLong() and 0xFF) or
                ((b[off + 1].toLong() and 0xFF) shl 8) or
                ((b[off + 2].toLong() and 0xFF) shl 16) or
                ((b[off + 3].toLong() and 0xFF) shl 24)
        }

        fun i32(b: ByteArray, off: Int): Int {
            return (b[off].toInt() and 0xFF) or
                ((b[off + 1].toInt() and 0xFF) shl 8) or
                ((b[off + 2].toInt() and 0xFF) shl 16) or
                ((b[off + 3].toInt() and 0xFF) shl 24)
        }
    }
}
