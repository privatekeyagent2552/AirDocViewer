package com.airdocsviewer

import android.app.Activity
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.hslf.usermodel.HSLFSlideShow
import org.apache.poi.hssf.eventusermodel.FormatTrackingHSSFListener
import org.apache.poi.hssf.eventusermodel.HSSFListener
import org.apache.poi.hssf.eventusermodel.MissingRecordAwareHSSFListener
import org.apache.poi.hssf.model.InternalWorkbook
import org.apache.poi.hssf.record.ContinueRecord
import org.apache.poi.hssf.record.RecordFactory
import org.apache.poi.hssf.record.RecordInputStream
import org.apache.poi.hssf.eventusermodel.dummyrecord.LastCellOfRowDummyRecord
import org.apache.poi.hssf.record.BOFRecord
import org.apache.poi.hssf.record.BlankRecord
import org.apache.poi.hssf.record.BoolErrRecord
import org.apache.poi.hssf.record.BoundSheetRecord
import org.apache.poi.hssf.record.FormulaRecord
import org.apache.poi.hssf.record.LabelRecord
import org.apache.poi.hssf.record.LabelSSTRecord
import org.apache.poi.hssf.record.NumberRecord
import org.apache.poi.hssf.record.RKRecord
import org.apache.poi.hssf.record.SSTRecord
import org.apache.poi.hssf.record.StringRecord
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import org.apache.poi.hwpf.usermodel.Paragraph as HwpfParagraph
import org.apache.poi.hwpf.usermodel.Range as HwpfRange
import org.apache.poi.openxml4j.opc.OPCPackage
import org.apache.poi.openxml4j.opc.PackagingURIHelper
import org.apache.poi.openxml4j.util.ZipSecureFile
import org.apache.poi.poifs.filesystem.POIFSFileSystem
import org.apache.poi.sl.usermodel.TextShape
import org.apache.poi.ss.usermodel.DataFormatter
import org.apache.poi.ss.util.CellReference
import org.apache.poi.util.IOUtils
import org.apache.poi.xslf.usermodel.XMLSlideShow
import org.apache.poi.xssf.eventusermodel.XSSFReader
import org.apache.poi.xssf.eventusermodel.XSSFSheetXMLHandler
import org.apache.poi.xssf.model.SharedStrings
import org.apache.poi.xssf.usermodel.XSSFComment
import org.apache.poi.xssf.usermodel.XSSFRichTextString
import org.apache.poi.xwpf.usermodel.BodyElementType
import org.apache.poi.xwpf.usermodel.UnderlinePatterns
import org.apache.poi.xwpf.usermodel.XWPFDocument
import org.apache.poi.xwpf.usermodel.XWPFHyperlinkRun
import org.apache.poi.xwpf.usermodel.XWPFParagraph
import org.apache.poi.xwpf.usermodel.XWPFRun
import org.apache.poi.xwpf.usermodel.XWPFTable
import org.apache.poi.xwpf.usermodel.XWPFTableCell
import org.apache.poi.xwpf.usermodel.XWPFTableRow
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler
import java.io.File
import java.io.InputStream
import java.io.PrintWriter
import java.io.StringWriter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipFile
import javax.xml.parsers.SAXParserFactory

class NativeDocumentParser(private val TAG: String) {

    /**
     * Hard caps so a single document cannot fill the 512MB Android large heap.
     * Callers may request less (thumbnails); they cannot request more.
     */
    private val maxRowsHard = 4_000
    private val maxColsHard = 24
    private val maxSheetsHard = 8
    private val maxCellChars = 256
    private val maxDocBlocks = 4_000
    private val maxSlides = 150
    private val maxSstEntries = 12_000
    private val maxSstChars = 750_000
    private val maxSstXmlBytes = 2_500_000L
    private val maxSheetXmlBytes = 4_000_000L
    /** Cells actually kept and sent to Flutter. Stops a dense sheet from filling the heap. */
    private val maxRetainedChars = 1_200_000
    private val maxRetainedCells = 60_000
    private val maxXlsBytes = 32L * 1024 * 1024
    private val maxDocBytes = 8L * 1024 * 1024
    private val maxPptBytes = 12L * 1024 * 1024
    private val maxPptxBytes = 48L * 1024 * 1024
    private val maxDocxXmlBytes = 12L * 1024 * 1024
    private val maxCsvBytes = 8L * 1024 * 1024

    private fun configurePoiLimits() {
        // One record / one zip entry must fail with an exception, not an OOM kill.
        IOUtils.setByteArrayMaxOverride(32 * 1024 * 1024)
        ZipSecureFile.setMaxEntrySize(48L * 1024 * 1024)
        ZipSecureFile.setMaxTextSize(16L * 1024 * 1024)
    }

    private fun bounded(requested: Int?, hard: Int): Int {
        val value = requested ?: hard
        return value.coerceIn(1, hard)
    }

    private fun ensureFileSize(file: File, maxBytes: Long, label: String) {
        val length = file.length()
        if (length > maxBytes) {
            val actualMb = (length / (1024 * 1024)).coerceAtLeast(1)
            val limitMb = (maxBytes / (1024 * 1024)).coerceAtLeast(1)
            throw IllegalStateException(
                "$label is too large to open safely on this device ($actualMb MB, limit $limitMb MB).",
            )
        }
    }

    private fun zipEntrySize(file: File, entryName: String): Long {
        return try {
            ZipFile(file).use { zip -> zip.getEntry(entryName)?.size ?: -1L }
        } catch (_: Exception) {
            -1L
        }
    }

    private fun logStep(step: String) {
        Log.i(TAG, "POI step: $step")
    }

    private fun logCauseChain(prefix: String, throwable: Throwable?) {
        var current = throwable
        var depth = 0
        while (current != null && depth < 12) {
            Log.e(TAG, "$prefix cause[$depth]: ${current::class.java.name}: ${current.message}")
            current = current.cause
            depth += 1
        }
    }

    private fun probeClass(className: String) {
        try {
            val clazz = Class.forName(className)
            Log.i(TAG, "POI probe OK: $className from ${clazz.protectionDomain?.codeSource?.location}")
        } catch (t: Throwable) {
            Log.e(TAG, "POI probe FAILED: $className", t)
            logCauseChain("POI probe FAILED: $className", t)
        }
    }

    fun handleParseDocument(
        filePath: String?,
        format: String?,
        maxRows: Int?,
        maxCols: Int?,
        maxSheets: Int?,
        result: MethodChannel.Result,
        activity: Activity,
    ) {
        var replied = false
        fun replySuccess(data: Any?) {
            if (replied) return
            replied = true
            deliverResult { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            deliverResult { result.error(code, message, null) }
        }
        try {
            configurePoiLimits()
            if (filePath == null || format == null) {
                replyError("INVALID_ARGS", "Missing filePath or format")
                return
            }

            Log.i(TAG, "Parsing document: $filePath (format: $format)")
            probeClass("org.apache.logging.log4j.LogManager")
            probeClass("org.apache.poi.util.IOUtils")
            probeClass("org.apache.poi.poifs.filesystem.FileMagic")
            val startTime = System.currentTimeMillis()

            val parsedData = when (format.uppercase()) {
                "XLSX" -> parseXLSX(filePath, maxRows, maxCols, maxSheets)
                "XLS" -> parseXLS(filePath, maxRows, maxCols, maxSheets)
                "CSV" -> parseCSV(filePath, maxRows, maxCols)
                "DOCX" -> parseDOCX(filePath)
                "DOC" -> parseDOC(filePath)
                "PDF" -> mapOf("format" to "PDF", "filePath" to filePath)
                "PPT", "PPTX" -> parsePresentation(filePath, format.uppercase())
                else -> throw IllegalArgumentException("Unsupported format: $format")
            }

            val duration = System.currentTimeMillis() - startTime
            Log.i(TAG, "Parse completed in ${duration}ms")
            replySuccess(parsedData)
        } catch (_: OutOfMemoryError) {
            // Error, not Exception: this is what escaped Method.invoke as
            // "Reflection load failed" / InvocationTargetException.
            Log.e(TAG, "Parse ran out of memory")
            replyError(
                "PARSE_ERROR",
                "This file is too large to open completely on this device.",
            )
        } catch (e: Exception) {
            Log.e(TAG, "Parse error", e)
            logCauseChain("Parse error", e)
            val sw = StringWriter()
            e.printStackTrace(PrintWriter(sw))
            replyError("PARSE_ERROR", "${e.message}\n${sw}")
        }
    }

    /** Finish the platform reply on the UI thread before the worker keeps another document alive. */
    private fun deliverResult(block: () -> Unit) {
        val latch = CountDownLatch(1)
        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    block()
                } finally {
                    latch.countDown()
                }
            }
        } catch (_: Exception) {
            latch.countDown()
        }
        latch.await(60, TimeUnit.SECONDS)
    }

    private fun parseXLSX(filePath: String, maxRows: Int?, maxCols: Int?, maxSheets: Int?): Map<String, Any> {
        logStep("parseXLSX:start streaming")
        val file = File(filePath)
        val rowLimit = bounded(maxRows, maxRowsHard)
        val colLimit = bounded(maxCols, maxColsHard)
        val sheetLimit = bounded(maxSheets, maxSheetsHard)
        val warnings = linkedSetOf<String>()
        val sheets = mutableListOf<Map<String, Any>>()
        var truncated = false
        val budget = TextBudget(maxRetainedChars, maxRetainedCells, maxCellChars)
        // StylesTable.readFrom() is XMLBeans DocumentFactory.parse of the whole
        // stylesheet plus ThemesTable. That live DOM is what fills the heap
        // before any sheet row is read. Numbers are shown without custom formats.
        logStep("parseXLSX:skip StylesTable")

        var pkg: OPCPackage? = null
        try {
            pkg = OPCPackage.open(file)
            val reader = XSSFReader(pkg)
            val strings = loadBoundedSharedStrings(pkg, warnings)
            val iterator = reader.sheetsData
            val named = iterator as? XSSFReader.SheetIterator
            var index = 0
            while (iterator.hasNext()) {
                val stream = iterator.next()
                try {
                    if (sheets.size >= sheetLimit || budget.exhausted) {
                        truncated = true
                        break
                    }
                    val name = named?.sheetName ?: "Sheet ${index + 1}"
                    val parsed = readXlsxSheet(stream, strings, rowLimit, colLimit, budget)
                    if (parsed.truncated || budget.exhausted) truncated = true
                    sheets.add(mapOf(
                        "name" to name,
                        "rows" to parsed.rows,
                        "rowCount" to parsed.rows.size,
                        "colCount" to (parsed.rows.firstOrNull()?.size ?: 0),
                    ))
                    index += 1
                } finally {
                    stream.close()
                }
            }
        } catch (_: OutOfMemoryError) {
            truncated = true
            warnings.add("Opened a partial copy because this workbook ran out of memory.")
            Log.e(TAG, "parseXLSX out of memory after ${sheets.size} sheets")
        } finally {
            try {
                pkg?.close()
            } catch (_: Exception) {
            }
        }

        if (truncated || warnings.isNotEmpty()) {
            warnings.add(
                "Showing the first $rowLimit rows and $colLimit columns so this spreadsheet fits in memory.",
            )
        }
        logStep("parseXLSX:done sheets=${sheets.size} truncated=$truncated")
        return mapOf(
            "sheets" to sheets,
            "sheetCount" to sheets.size,
            "format" to "XLSX",
            "filePath" to filePath,
            "parseWarnings" to warnings.toList(),
        )
    }

    private fun parseXLS(filePath: String, maxRows: Int?, maxCols: Int?, maxSheets: Int?): Map<String, Any> {
        logStep("parseXLS:start streaming")
        val file = File(filePath)
        ensureFileSize(file, maxXlsBytes, "This .xls workbook")
        val rowLimit = bounded(maxRows, maxRowsHard)
        val colLimit = bounded(maxCols, maxColsHard)
        val sheetLimit = bounded(maxSheets, maxSheetsHard)
        val warnings = linkedSetOf<String>()
        val budget = TextBudget(maxRetainedChars, maxRetainedCells, maxCellChars)
        val reader = XlsEventReader(rowLimit, colLimit, sheetLimit, budget)
        val fs = POIFSFileSystem(file, true)
        try {
            val missingAware = MissingRecordAwareHSSFListener(reader)
            val formatListener = FormatTrackingHSSFListener(missingAware)
            reader.formatListener = formatListener
            try {
                // Do not use HSSFEventFactory: it builds a full SSTRecord and
                // keeps every shared string before the row cap can run.
                processXlsRecords(fs, formatListener, reader)
            } catch (e: Exception) {
                if (!isSheetRowLimit(e)) throw e
                reader.truncated = true
            } catch (_: OutOfMemoryError) {
                reader.truncated = true
                warnings.add("Opened a partial copy because this workbook ran out of memory.")
                Log.e(TAG, "parseXLS out of memory after ${reader.sheets.size} sheets")
            }
            try {
                reader.finishSheet()
            } catch (_: OutOfMemoryError) {
                reader.truncated = true
            }
        } finally {
            fs.close()
        }

        if (reader.truncated) {
            warnings.add(
                "Showing the first $rowLimit rows and $colLimit columns so this spreadsheet fits in memory.",
            )
        }
        logStep("parseXLS:done sheets=${reader.sheets.size} truncated=${reader.truncated}")
        return mapOf(
            "sheets" to reader.sheets,
            "sheetCount" to reader.sheets.size,
            "format" to "XLS",
            "filePath" to filePath,
            "parseWarnings" to warnings.toList(),
        )
    }

    private fun parsePresentation(filePath: String, format: String): Map<String, Any> {
        logStep("parsePresentation:start ($format)")
        val file = File(filePath)
        val normalized = format.uppercase()
        if (normalized == "PPT") {
            ensureFileSize(file, maxPptBytes, "This .ppt presentation")
        } else {
            ensureFileSize(file, maxPptxBytes, "This .pptx presentation")
        }
        // Open from a file, not an InputStream. POI buffers an entire InputStream
        // into one byte[] (the whole deck, including pictures) before parsing.
        // HSLFSlideShow has no File constructor; POIFSFileSystem(File) reads the
        // OLE container from disk and HSLFSlideShow takes ownership of it.
        logStep("parsePresentation:before open")
        val slideShow: org.apache.poi.sl.usermodel.SlideShow<*, *> = if (normalized == "PPT") {
            val fs = POIFSFileSystem(file)
            try {
                HSLFSlideShow(fs)
            } catch (t: Throwable) {
                try {
                    fs.close()
                } catch (_: Exception) {
                }
                throw t
            }
        } else {
            XMLSlideShow(OPCPackage.open(file))
        } as org.apache.poi.sl.usermodel.SlideShow<*, *>
        logStep("parsePresentation:after open")
        var closed = false
        try {
            val slides = mutableListOf<Map<String, Any>>()
            val documentBlocks = mutableListOf<Map<String, Any>>()
            val allText = StringBuilder()
            val warnings = linkedSetOf(
                "Presentation shows slide text, headings, and detected bullets without original layout or images.",
            )

            var index = 1
            for (slide in slideShow.slides) {
                if (index > maxSlides) {
                    warnings.add(
                        "Showing the first $maxSlides slides so this presentation fits in memory.",
                    )
                    break
                }
                val slideText = StringBuilder()
                val shapeTexts = mutableListOf<String>()
                val shapes = try {
                    slide.shapes
                } catch (t: Throwable) {
                    Log.w(TAG, "Skip shapes on slide $index: ${t.message}")
                    warnings.add("Some shapes on slide $index could not be read.")
                    emptyList()
                }
                for (shape in shapes) {
                    try {
                        if (shape is TextShape<*, *>) {
                            val text = shape.text
                            if (!text.isNullOrBlank()) {
                                val trimmed = OfficeGlyphSanitizer.sanitize(text.trimEnd())
                                shapeTexts.add(trimmed)
                                slideText.append(trimmed).append("\n")
                            }
                        }
                    } catch (t: Throwable) {
                        Log.w(TAG, "Skip shape on slide $index: ${t.message}")
                        warnings.add("Some content on slide $index was skipped.")
                    }
                }
                val text = slideText.toString().trimEnd()
                slides.add(mapOf("slideNumber" to index, "text" to text))
                if (text.isNotEmpty()) {
                    allText.append("[Slide ").append(index).append("]\n")
                    allText.append(text).append("\n\n")
                }

                documentBlocks.add(
                    mapOf(
                        "type" to "paragraph",
                        "inlines" to listOf(
                            mapOf(
                                "type" to "text",
                                "text" to "Slide $index",
                                "style" to mapOf("bold" to true, "fontSize" to 16.0)
                            )
                        )
                    )
                )
                if (shapeTexts.isEmpty() && text.isEmpty()) {
                    documentBlocks.add(
                        mapOf(
                            "type" to "paragraph",
                            "inlines" to listOf(
                                mapOf(
                                    "type" to "text",
                                    "text" to "(slide content extracted later)",
                                    "style" to emptyMap<String, Any>()
                                )
                            )
                        )
                    )
                }
                for ((shapeIndex, shapeText) in shapeTexts.withIndex()) {
                    val lines = shapeText.split(Regex("\\r\\n|\\r|\\n"))
                        .map { it.trimEnd() }
                        .filter { it.isNotBlank() }
                    for (line in lines) {
                        val looksLikeBullet = line.startsWith("•") ||
                            line.startsWith("- ") ||
                            line.startsWith("* ") ||
                            line.startsWith("–") ||
                            Regex("^\\d+[.)]\\s+").containsMatchIn(line)
                        val cleaned = line
                            .removePrefix("•")
                            .removePrefix("* ")
                            .removePrefix("- ")
                            .removePrefix("–")
                            .replaceFirst(Regex("^\\d+[.)]\\s+"), "")
                            .trim()
                        documentBlocks.add(
                            mapOf(
                                "type" to "paragraph",
                                "inlines" to listOf(
                                    mapOf(
                                        "type" to "text",
                                        "text" to cleaned.ifBlank { line },
                                        "style" to if (shapeIndex == 0 && lines.indexOf(line) == 0)
                                            mapOf("bold" to true, "fontSize" to 14.0)
                                        else emptyMap<String, Any>()
                                    )
                                ),
                                "listLevel" to if (looksLikeBullet) 0 else null,
                                "listKind" to if (looksLikeBullet) {
                                    if (Regex("^\\d+[.)]").containsMatchIn(line)) "decimal" else "bullet"
                                } else null
                            ).filterValues { it != null } as Map<String, Any>
                        )
                    }
                }
                documentBlocks.add(
                    mapOf(
                        "type" to "spacer",
                        "height" to 20.0,
                        "isPageBreak" to true
                    )
                )
                index++
            }

            var plainText = OfficeGlyphSanitizer.sanitize(allText.toString().trim())
            var bulkText = ""
            if (plainText.isBlank()) {
                // Drop the slideshow model before a second parse so both copies
                // are never on the heap together.
                closed = true
                slideShow.close()
                try {
                    bulkText = extractPresentationPlainText(filePath, normalized)
                } catch (t: Throwable) {
                    Log.w(TAG, "Bulk presentation extractor failed: ${t.message}")
                }
            }
            if (plainText.isBlank() && bulkText.isNotBlank()) {
                plainText = OfficeGlyphSanitizer.sanitize(bulkText.trim())
                warnings.add("Used bulk text extraction because per-shape parsing returned little content.")
                if (documentBlocks.none { block ->
                        ((block["inlines"] as? List<*>)?.any { inline ->
                            (inline as? Map<*, *>)?.get("text")?.toString()?.isNotBlank() == true &&
                                inline["text"] != "Slide 1" &&
                                !(inline["text"] as String).startsWith("Slide ")
                        } == true)
                    }) {
                    documentBlocks.clear()
                    for (para in plainText.split(Regex("\\n\\s*\\n+|\\n"))) {
                        val line = para.trim()
                        if (line.isEmpty()) continue
                        documentBlocks.add(
                            mapOf(
                                "type" to "paragraph",
                                "inlines" to listOf(
                                    mapOf(
                                        "type" to "text",
                                        "text" to line,
                                        "style" to emptyMap<String, Any>()
                                    )
                                )
                            )
                        )
                    }
                }
                if (slides.all { ((it["text"] as? String).orEmpty()).isBlank() }) {
                    slides.clear()
                    slides.add(mapOf("slideNumber" to 1, "text" to plainText))
                }
            }

            val wordCount = plainText.split(Regex("\\s+")).count { it.isNotBlank() }
            val lineCount = plainText.split(Regex("\\r\\n|\\r|\\n")).count { it.isNotBlank() }.coerceAtLeast(1)

            Log.w(
                TAG,
                "Presentation parse OK format=$format slides=${slides.size} chars=${plainText.length}",
            )

            return mapOf(
                "textContent" to plainText,
                "plainTextContent" to plainText,
                "slides" to slides,
                "slideCount" to slides.size.coerceAtLeast(if (plainText.isNotEmpty()) 1 else 0),
                "documentBlocks" to documentBlocks,
                "parseWarnings" to warnings.toList(),
                "fidelityLevel" to if (plainText.isNotEmpty()) "partial" else "plainText",
                "wordCount" to wordCount,
                "lineCount" to lineCount,
                "format" to format,
                "filePath" to filePath
            )
        } finally {
            if (!closed) {
                slideShow.close()
            }
        }
    }

    /** Text-only fallback. Opens from a file so the zip/OLE container is not copied into a byte[]. */
    private fun extractPresentationPlainText(filePath: String, format: String): String {
        val file = File(filePath)
        return when (format.uppercase()) {
            "PPT" -> {
                val clazz = Class.forName("org.apache.poi.hslf.extractor.PowerPointExtractor")
                val fs = POIFSFileSystem(file)
                try {
                    val show = HSLFSlideShow(fs)
                    val extractor = clazz.getConstructor(
                        Class.forName("org.apache.poi.hslf.usermodel.HSLFSlideShow"),
                    ).newInstance(show)
                    try {
                        (clazz.getMethod("getText").invoke(extractor) as? String).orEmpty()
                    } finally {
                        try {
                            clazz.getMethod("close").invoke(extractor)
                        } catch (_: Throwable) {
                        }
                    }
                } finally {
                    try {
                        fs.close()
                    } catch (_: Exception) {
                    }
                }
            }
            else -> {
                val pkg = OPCPackage.open(file)
                try {
                    val show = XMLSlideShow(pkg)
                    try {
                        val clazz = Class.forName("org.apache.poi.xslf.extractor.XSLFPowerPointExtractor")
                        val extractor = clazz.getConstructor(
                            Class.forName("org.apache.poi.xslf.usermodel.XMLSlideShow"),
                        ).newInstance(show)
                        try {
                            (clazz.getMethod("getText").invoke(extractor) as? String).orEmpty()
                        } finally {
                            try {
                                clazz.getMethod("close").invoke(extractor)
                            } catch (_: Throwable) {
                            }
                        }
                    } finally {
                        show.close()
                    }
                } finally {
                    try {
                        pkg.close()
                    } catch (_: Exception) {
                    }
                }
            }
        }
    }

    private fun parseCSV(filePath: String, maxRows: Int?, maxCols: Int?): Map<String, Any> {
        val file = File(filePath)
        val rowLimit = bounded(maxRows, maxRowsHard)
        val colLimit = bounded(maxCols, maxColsHard)
        val rows = mutableListOf<List<String>>()
        val warnings = linkedSetOf<String>()
        var truncated = file.length() > maxCsvBytes
        var bytesRead = 0L

        file.bufferedReader().use { reader ->
            while (rows.size < rowLimit && bytesRead < maxCsvBytes) {
                val line = reader.readLine() ?: break
                bytesRead += line.length + 1
                if (line.length > 64 * 1024) {
                    truncated = true
                    rows.add(listOf(line.take(maxCellChars)))
                    continue
                }
                if (line.trim().isEmpty()) continue

                val cells = mutableListOf<String>()
                var currentCell = StringBuilder()
                var inQuotes = false

                for (char in line) {
                    when {
                        char == '"' -> inQuotes = !inQuotes
                        char == ',' && !inQuotes -> {
                            cells.add(currentCell.toString().trim().take(maxCellChars))
                            currentCell = StringBuilder()
                            if (cells.size >= colLimit) break
                        }
                        else -> if (currentCell.length < maxCellChars) currentCell.append(char)
                    }
                }

                if (cells.size < colLimit && currentCell.isNotEmpty()) {
                    cells.add(currentCell.toString().trim().take(maxCellChars))
                }

                if (cells.isNotEmpty()) {
                    rows.add(cells)
                }
            }
            if (reader.readLine() != null) truncated = true
        }

        if (truncated) {
            warnings.add(
                "Showing the first $rowLimit rows and $colLimit columns so this spreadsheet fits in memory.",
            )
        }

        return mapOf(
            "sheets" to listOf(mapOf(
                "name" to "Sheet1",
                "rows" to rows,
                "rowCount" to rows.size,
                "colCount" to (rows.firstOrNull()?.size ?: 0)
            )),
            "sheetCount" to 1,
            "format" to "CSV",
            "filePath" to filePath,
            "parseWarnings" to warnings.toList(),
        )
    }

    private fun parseDOCX(filePath: String): Map<String, Any> {
        logStep("parseDOCX:start")
        val file = File(filePath)
        val xmlSize = zipEntrySize(file, "word/document.xml")
        if (xmlSize > maxDocxXmlBytes) {
            throw IllegalStateException(
                "This document is too large to open safely on this device.",
            )
        }
        logStep("parseDOCX:before XWPFDocument")
        val document = XWPFDocument(OPCPackage.open(file))
        logStep("parseDOCX:after XWPFDocument")

        try {
            val blocks = mutableListOf<Map<String, Any>>()
            val warnings = linkedSetOf<String>()
            var truncated = false

            for (element in document.bodyElements) {
                if (blocks.size >= maxDocBlocks) {
                    truncated = true
                    break
                }
                when (element.elementType) {
                    BodyElementType.PARAGRAPH -> {
                        val paragraphBlock = parseDocxParagraph(element as XWPFParagraph, warnings)
                        if (paragraphBlock != null) {
                            blocks.add(paragraphBlock)
                        }
                    }
                    BodyElementType.TABLE -> {
                        blocks.add(parseDocxTable(element as XWPFTable, warnings))
                    }
                    else -> {
                        warnings.add("Unsupported DOCX body element skipped: ${element.elementType}")
                    }
                }
            }

            if (truncated) {
                warnings.add(
                    "Showing the first $maxDocBlocks blocks so this document fits in memory.",
                )
            }
            val plainText = blocks.joinToString("\n") { flattenBlockText(it) }.trim()
            val wordCount = plainText.split(Regex("\\s+")).count { it.isNotBlank() }
            val lineCount = plainText.split(Regex("\\r\\n|\\r|\\n")).count { it.isNotBlank() }

            return mapOf(
                "textContent" to plainText,
                "plainTextContent" to plainText,
                "documentBlocks" to blocks,
                "parseWarnings" to warnings.toList(),
                "fidelityLevel" to if (warnings.isEmpty()) "rich" else "partial",
                "wordCount" to wordCount,
                "lineCount" to lineCount.coerceAtLeast(1),
                "format" to "DOCX",
                "filePath" to filePath
            )
        } finally {
            document.close()
        }
    }

    private fun parseDOC(filePath: String): Map<String, Any> {
        logStep("parseDOC:start")
        val file = File(filePath)
        ensureFileSize(file, maxDocBytes, "This .doc document")
        logStep("parseDOC:before HWPFDocument")
        val document = HWPFDocument(POIFSFileSystem(file, true))
        logStep("parseDOC:after HWPFDocument")
        val extractor = WordExtractor(document)

        try {
            val text = extractor.text
            val documentBlocks = mutableListOf<Map<String, Any>>()
            val range: HwpfRange = document.range
            val paragraphCount = range.numParagraphs()
            val paragraphLimit = minOf(paragraphCount, maxDocBlocks)
            for (i in 0 until paragraphLimit) {
                val paragraph: HwpfParagraph = range.getParagraph(i)
                val paragraphText = OfficeGlyphSanitizer.sanitize(
                    paragraph.text()
                        ?.replace("\u0007", "")
                        ?.trimEnd()
                        .orEmpty()
                )
                if (paragraphText.isBlank()) continue

                val inlines = mutableListOf<Map<String, Any>>()
                val style = mutableMapOf<String, Any>()
                // Character-run styling is best-effort for legacy DOC.
                try {
                    if (paragraph.numCharacterRuns() > 0) {
                        val run = paragraph.getCharacterRun(0)
                        if (run.isBold) style["bold"] = true
                        if (run.isItalic) style["italic"] = true
                        if (run.isStrikeThrough) style["strike"] = true
                        if (run.underlineCode > 0) style["underline"] = true
                    }
                } catch (_: Throwable) {
                    // Ignore run styling when unavailable.
                }

                inlines.add(
                    mapOf(
                        "type" to "text",
                        "text" to paragraphText,
                        "style" to style
                    )
                )

                val block = mutableMapOf<String, Any>(
                    "type" to "paragraph",
                    "inlines" to inlines
                )
                try {
                    val ilvl = paragraph.ilvl
                    val ilfo = paragraph.ilfo
                    if (ilfo > 0) {
                        block["listLevel"] = ilvl.coerceAtLeast(0)
                        block["listKind"] = "num:$ilfo"
                    }
                } catch (_: Throwable) {
                    // Ignore list metadata when unavailable.
                }
                documentBlocks.add(block)
            }

            if (documentBlocks.isEmpty()) {
                val paragraphs = extractor.paragraphText
                    ?.mapNotNull { it?.replace("\u0007", "")?.trimEnd() }
                    ?.filter { it.isNotBlank() }
                    ?: emptyList()
                for (paragraphText in paragraphs) {
                    documentBlocks.add(
                        mapOf(
                            "type" to "paragraph",
                            "inlines" to listOf(
                                mapOf(
                                    "type" to "text",
                                    "text" to paragraphText,
                                    "style" to emptyMap<String, Any>()
                                )
                            )
                        )
                    )
                }
            }

            val wordCount = text.split(Regex("\\s+")).count { it.isNotBlank() }
            val lineCount = documentBlocks.size.coerceAtLeast(1)
            return mapOf(
                "textContent" to text,
                "plainTextContent" to text,
                "documentBlocks" to documentBlocks,
                "parseWarnings" to listOf(
                    "Legacy DOC shows paragraphs, basic styles, and list levels when available.",
                ) + if (paragraphCount > paragraphLimit) {
                    listOf("Showing the first $maxDocBlocks paragraphs so this document fits in memory.")
                } else {
                    emptyList()
                },
                "fidelityLevel" to "partial",
                "wordCount" to wordCount,
                "lineCount" to lineCount,
                "format" to "DOC",
                "filePath" to filePath
            )
        } finally {
            extractor.close()
            document.close()
        }
    }

    private fun parseDocxParagraph(
        paragraph: XWPFParagraph,
        warnings: MutableSet<String>
    ): Map<String, Any>? {
        val inlines = mutableListOf<Map<String, Any>>()

        for (run in paragraph.runs) {
            inlines.addAll(parseDocxRun(run, warnings))
        }

        if (inlines.isEmpty()) {
            val text = paragraph.text?.trimEnd().orEmpty()
            if (text.isBlank()) {
                return null
            }
            inlines.add(
                mapOf(
                    "type" to "text",
                    "text" to text,
                    "style" to emptyMap<String, Any>()
                )
            )
        }

        val paragraphBlock = mutableMapOf<String, Any>(
            "type" to "paragraph",
            "inlines" to inlines
        )

        paragraph.alignment?.let { paragraphBlock["alignment"] = it.name.lowercase() }
        if (paragraph.spacingBefore > 0) {
            paragraphBlock["spacingBefore"] = paragraph.spacingBefore.toDouble() / 20.0
        }
        if (paragraph.spacingAfter > 0) {
            paragraphBlock["spacingAfter"] = paragraph.spacingAfter.toDouble() / 20.0
        }
        if (paragraph.firstLineIndent > 0) {
            paragraphBlock["firstLineIndent"] = paragraph.firstLineIndent.toDouble() / 20.0
        }
        if (paragraph.indentationLeft > 0) {
            paragraphBlock["leftIndent"] = paragraph.indentationLeft.toDouble() / 20.0
        }
        if (paragraph.indentationRight > 0) {
            paragraphBlock["rightIndent"] = paragraph.indentationRight.toDouble() / 20.0
        }
        paragraph.numIlvl?.toInt()?.let { paragraphBlock["listLevel"] = it }
        paragraph.numID?.toString()?.let { paragraphBlock["listKind"] = "num:$it" }

        return paragraphBlock
    }

    private fun parseDocxRun(
        run: XWPFRun,
        warnings: MutableSet<String>
    ): List<Map<String, Any>> {
        val inlines = mutableListOf<Map<String, Any>>()
        val style = mutableMapOf<String, Any>()

        if (run.isBold) style["bold"] = true
        if (run.isItalic) style["italic"] = true
        if (run.isStrikeThrough) style["strike"] = true
        if (run.underline != UnderlinePatterns.NONE) style["underline"] = true
        run.fontFamily?.takeIf { it.isNotBlank() }?.let {
            if (!OfficeGlyphSanitizer.isSymbolFont(it)) {
                style["fontFamily"] = it
            }
        }
        if (run.fontSize > 0) style["fontSize"] = run.fontSize.toDouble()
        run.color?.takeIf { it.isNotBlank() }?.let { style["colorHex"] = it }
        run.textHightlightColor?.toString()?.takeIf { it.isNotBlank() }?.let { style["backgroundHex"] = it }

        val runText = OfficeGlyphSanitizer.sanitize(buildString {
            var textIndex = 0
            while (true) {
                val value = run.getText(textIndex) ?: break
                append(value)
                textIndex++
            }
        })

        if (runText.isNotEmpty()) {
            val type = if (run is XWPFHyperlinkRun) "hyperlink" else "text"
            val inline = mutableMapOf<String, Any>(
                "type" to type,
                "text" to runText,
                "style" to style
            )
            if (run is XWPFHyperlinkRun) {
                val hyperlinkUrl = run
                    .getHyperlink(run.document)
                    ?.url
                    ?.takeIf { it.isNotBlank() }
                if (hyperlinkUrl != null) {
                    inline["href"] = hyperlinkUrl
                }
            }
            inlines.add(inline)
        }

        val hasDrawing = try {
            val ctr = run.ctr
            (ctr?.drawingList?.isNotEmpty() == true) || (ctr?.pictList?.isNotEmpty() == true)
        } catch (_: Throwable) {
            false
        }
        if (hasDrawing) {
            warnings.add("Embedded images are omitted so this document fits in memory.")
            inlines.add(
                mapOf(
                    "type" to "text",
                    "text" to "[Image]",
                    "style" to style
                )
            )
        }

        if (runText.isEmpty() && !hasDrawing) {
            val fallbackText = run.toString()
            if (fallbackText.isNotBlank()) {
                inlines.add(
                    mapOf(
                        "type" to "text",
                        "text" to fallbackText,
                        "style" to style
                    )
                )
            }
        }

        return inlines
    }

    private fun parseDocxTable(
        table: XWPFTable,
        warnings: MutableSet<String>
    ): Map<String, Any> {
        val rows = mutableListOf<Map<String, Any>>()
        for (row in table.rows) {
            rows.add(parseDocxTableRow(row, warnings))
        }
        return mapOf(
            "type" to "table",
            "rows" to rows
        )
    }

    private fun parseDocxTableRow(
        row: XWPFTableRow,
        warnings: MutableSet<String>
    ): Map<String, Any> {
        val cells = row.tableCells.map { parseDocxTableCell(it, warnings) }
        return mapOf("cells" to cells)
    }

    private fun parseDocxTableCell(
        cell: XWPFTableCell,
        warnings: MutableSet<String>
    ): Map<String, Any> {
        val blocks = mutableListOf<Map<String, Any>>()
        for (element in cell.bodyElements) {
            when (element.elementType) {
                BodyElementType.PARAGRAPH -> {
                    val paragraphBlock = parseDocxParagraph(element as XWPFParagraph, warnings)
                    if (paragraphBlock != null) {
                        blocks.add(paragraphBlock)
                    }
                }
                BodyElementType.TABLE -> {
                    warnings.add("Nested DOCX tables are rendered as nested table blocks.")
                    blocks.add(parseDocxTable(element as XWPFTable, warnings))
                }
                else -> {
                    warnings.add("Unsupported DOCX table cell element skipped: ${element.elementType}")
                }
            }
        }
        return mapOf("blocks" to blocks)
    }

    private fun flattenBlockText(block: Map<String, Any>): String {
        return when (block["type"]) {
            "paragraph" -> {
                @Suppress("UNCHECKED_CAST")
                val inlines = block["inlines"] as? List<Map<String, Any>> ?: emptyList()
                inlines.joinToString(separator = "") { inline ->
                    when (inline["type"] as? String) {
                        "tab" -> "\t"
                        "lineBreak" -> "\n"
                        else -> inline["text"] as? String ?: ""
                    }
                }
            }
            "table" -> {
                @Suppress("UNCHECKED_CAST")
                val rows = block["rows"] as? List<Map<String, Any>> ?: emptyList()
                rows.joinToString(separator = "\n") { row ->
                    @Suppress("UNCHECKED_CAST")
                    val cells = row["cells"] as? List<Map<String, Any>> ?: emptyList()
                    cells.joinToString(separator = "\t") { cell ->
                        @Suppress("UNCHECKED_CAST")
                        val blocks = cell["blocks"] as? List<Map<String, Any>> ?: emptyList()
                        blocks.joinToString(separator = "\n") { flattenBlockText(it) }
                    }
                }
            }
            else -> ""
        }
    }

    private data class SheetRead(val rows: List<List<String>>, val truncated: Boolean)

    private fun readXlsxSheet(
        stream: InputStream,
        strings: SharedStrings,
        rowLimit: Int,
        colLimit: Int,
        budget: TextBudget,
    ): SheetRead {
        val rows = mutableListOf<List<String>>()
        var truncated = false
        val contents = object : XSSFSheetXMLHandler.SheetContentsHandler {
            val current = mutableListOf<String>()
            var nextCol = 0

            override fun startRow(rowNum: Int) {
                current.clear()
                nextCol = 0
            }

            override fun endRow(rowNum: Int) {
                if (current.any { it.isNotEmpty() }) {
                    rows.add(current.toList())
                }
                if (rows.size >= rowLimit || budget.exhausted) {
                    throw SheetRowLimitException()
                }
            }

            override fun cell(cellReference: String?, formattedValue: String?, comment: XSSFComment?) {
                val col = if (!cellReference.isNullOrEmpty()) {
                    try {
                        CellReference(cellReference).col.toInt()
                    } catch (_: Exception) {
                        nextCol
                    }
                } else {
                    nextCol
                }
                nextCol = col + 1
                if (col >= colLimit || budget.exhausted) {
                    truncated = true
                    if (budget.exhausted) throw SheetRowLimitException()
                    return
                }
                if (col < 0) return
                while (current.size <= col) current.add("")
                current[col] = budget.take(formattedValue)
                if (budget.exhausted) {
                    truncated = true
                    throw SheetRowLimitException()
                }
            }
        }

        val factory = SAXParserFactory.newInstance()
        factory.isNamespaceAware = true
        try {
            factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
            factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
        } catch (_: Exception) {
        }
        val xmlReader = factory.newSAXParser().xmlReader
        xmlReader.contentHandler = XSSFSheetXMLHandler(
            null,
            null,
            strings,
            contents,
            DataFormatter(),
            false,
        )
        val capped = CappedInputStream(stream, maxSheetXmlBytes)
        try {
            xmlReader.parse(InputSource(capped))
        } catch (e: SAXException) {
            if (!isSheetRowLimit(e) && !capped.hitCap) throw e
            truncated = true
        } catch (e: RuntimeException) {
            if (!isSheetRowLimit(e) && !capped.hitCap) throw e
            truncated = true
        }
        if (capped.hitCap) truncated = true
        return SheetRead(rows, truncated)
    }

    private fun loadBoundedSharedStrings(pkg: OPCPackage, warnings: MutableSet<String>): SharedStrings {
        val partName = PackagingURIHelper.createPartName("/xl/sharedStrings.xml")
        if (!pkg.containPart(partName)) {
            return BoundedSharedStrings(emptyList())
        }
        val handler = BoundedSstHandler(maxSstEntries, maxSstChars, maxCellChars)
        pkg.getPart(partName).inputStream.use { input ->
            val capped = CappedInputStream(input, maxSstXmlBytes)
            val factory = SAXParserFactory.newInstance()
            factory.isNamespaceAware = true
            try {
                factory.setFeature("http://xml.org/sax/features/external-general-entities", false)
                factory.setFeature("http://xml.org/sax/features/external-parameter-entities", false)
            } catch (_: Exception) {
            }
            try {
                factory.newSAXParser().parse(InputSource(capped), handler)
            } catch (e: SAXException) {
                if (!isSheetRowLimit(e) && !capped.hitCap) throw e
                warnings.add("Some spreadsheet text was skipped to stay within memory limits.")
            } catch (e: RuntimeException) {
                if (!isSheetRowLimit(e) && !capped.hitCap) throw e
                warnings.add("Some spreadsheet text was skipped to stay within memory limits.")
            }
            if (capped.hitCap) {
                warnings.add("Some spreadsheet text was skipped to stay within memory limits.")
            }
        }
        return BoundedSharedStrings(handler.values)
    }

    private fun isSheetRowLimit(error: Throwable?): Boolean {
        var current = error
        while (current != null) {
            if (current is SheetRowLimitException) return true
            current = current.cause
        }
        return false
    }

    private class SheetRowLimitException : RuntimeException("row-limit")

    private class BoundedSharedStrings(private val values: List<String>) : SharedStrings {
        override fun getItemAt(idx: Int): org.apache.poi.ss.usermodel.RichTextString {
            val text = if (idx in values.indices) values[idx] else ""
            return XSSFRichTextString(text)
        }

        override fun getCount(): Int = values.size

        override fun getUniqueCount(): Int = values.size
    }

    private class BoundedSstHandler(
        private val maxEntries: Int,
        private val maxChars: Int,
        private val maxItemChars: Int,
    ) : DefaultHandler() {
        val values = ArrayList<String>()
        private val current = StringBuilder()
        private var inText = false
        private var chars = 0

        override fun startElement(uri: String?, localName: String?, qName: String?, attributes: Attributes?) {
            when (xmlName(localName, qName)) {
                "si" -> current.setLength(0)
                "t" -> inText = true
            }
        }

        override fun characters(ch: CharArray?, start: Int, length: Int) {
            if (!inText || ch == null || chars >= maxChars || values.size >= maxEntries) return
            val room = minOf(length, maxItemChars - current.length, maxChars - chars)
            if (room > 0) {
                current.append(ch, start, room)
                chars += room
            }
        }

        override fun endElement(uri: String?, localName: String?, qName: String?) {
            when (xmlName(localName, qName)) {
                "t" -> inText = false
                "si" -> {
                    if (values.size >= maxEntries || chars >= maxChars) {
                        throw SheetRowLimitException()
                    }
                    values.add(current.toString())
                }
            }
        }

        private fun xmlName(localName: String?, qName: String?): String {
            if (!localName.isNullOrEmpty()) return localName
            return qName?.substringAfter(':') ?: ""
        }
    }

    /**
     * Reads .xls records into plain strings. Does not build an [org.apache.poi.hssf.usermodel.HSSFWorkbook],
     * which would keep every cell, style, and formula as a live object.
     */
    private class XlsEventReader(
        private val rowLimit: Int,
        private val colLimit: Int,
        private val sheetLimit: Int,
        private val budget: TextBudget,
    ) : HSSFListener {
        val sheets = mutableListOf<Map<String, Any>>()
        var truncated = false
        var sharedStrings: List<String> = emptyList()
        var sstTruncated = false
        lateinit var formatListener: FormatTrackingHSSFListener

        private val sheetNames = mutableListOf<String>()
        private val currentRows = mutableListOf<List<String>>()
        private val currentRow = mutableListOf<String>()
        private var sheetOpen = false
        private var acceptCells = true
        private var outputNextString = false
        private var nextRow = -1
        private var nextColumn = -1

        override fun processRecord(record: org.apache.poi.hssf.record.Record) {
            var row = -1
            var col = -1
            var value: String? = null

            when (record.sid.toInt()) {
                BoundSheetRecord.sid.toInt() -> {
                    val name = (record as BoundSheetRecord).getSheetname()
                    if (sheetNames.size < sheetLimit) {
                        sheetNames.add(name?.ifBlank { null } ?: "Sheet ${sheetNames.size + 1}")
                    }
                }
                BOFRecord.sid.toInt() -> {
                    val bof = record as BOFRecord
                    if (bof.type == BOFRecord.TYPE_WORKSHEET) {
                        finishSheet()
                        if (sheets.size >= sheetLimit) {
                            truncated = true
                            throw SheetRowLimitException()
                        }
                        sheetOpen = true
                        acceptCells = true
                    }
                }
                SSTRecord.sid.toInt() -> {
                    // A full SSTRecord retains every shared string. readBoundedSst
                    // already loaded a capped list; drop this record if it appears.
                }
                BlankRecord.sid.toInt() -> {
                    val cell = record as BlankRecord
                    row = cell.row
                    col = cell.column.toInt()
                    value = ""
                }
                BoolErrRecord.sid.toInt() -> {
                    val cell = record as BoolErrRecord
                    row = cell.row
                    col = cell.column.toInt()
                    value = if (cell.isBoolean()) cell.getBooleanValue().toString() else "ERROR"
                }
                FormulaRecord.sid.toInt() -> {
                    val cell = record as FormulaRecord
                    row = cell.row
                    col = cell.column.toInt()
                    if (java.lang.Double.isNaN(cell.value)) {
                        outputNextString = true
                        nextRow = row
                        nextColumn = col
                        value = null
                    } else {
                        value = formatListener.formatNumberDateCell(cell)
                    }
                }
                StringRecord.sid.toInt() -> {
                    if (outputNextString) {
                        value = (record as StringRecord).string
                        row = nextRow
                        col = nextColumn
                        outputNextString = false
                    }
                }
                LabelRecord.sid.toInt() -> {
                    val cell = record as LabelRecord
                    row = cell.row
                    col = cell.column.toInt()
                    value = cell.value
                }
                LabelSSTRecord.sid.toInt() -> {
                    val cell = record as LabelSSTRecord
                    row = cell.row
                    col = cell.column.toInt()
                    val index = cell.sstIndex
                    value = if (index in sharedStrings.indices) {
                        sharedStrings[index]
                    } else {
                        if (sstTruncated) truncated = true
                        ""
                    }
                }
                NumberRecord.sid.toInt() -> {
                    val cell = record as NumberRecord
                    row = cell.row
                    col = cell.column.toInt()
                    value = formatListener.formatNumberDateCell(cell)
                }
                RKRecord.sid.toInt() -> {
                    val cell = record as RKRecord
                    row = cell.row
                    col = cell.column.toInt()
                    value = formatListener.formatNumberDateCell(cell)
                }
            }

            if (record is LastCellOfRowDummyRecord) {
                commitRow()
                return
            }
            if (value != null && acceptCells) {
                putCell(col, value)
            }
        }

        fun finishSheet() {
            if (!sheetOpen) return
            commitRow()
            val name = sheetNames.getOrNull(sheets.size) ?: "Sheet ${sheets.size + 1}"
            sheets.add(mapOf(
                "name" to name,
                "rows" to currentRows.toList(),
                "rowCount" to currentRows.size,
                "colCount" to (currentRows.firstOrNull()?.size ?: 0),
            ))
            currentRows.clear()
            sheetOpen = false
            acceptCells = false
        }

        private fun commitRow() {
            if (!sheetOpen || !acceptCells) {
                currentRow.clear()
                return
            }
            if (currentRow.any { it.isNotEmpty() } && currentRows.size < rowLimit) {
                currentRows.add(currentRow.toList())
            }
            currentRow.clear()
            if (currentRows.size >= rowLimit) {
                truncated = true
                acceptCells = false
            }
        }

        private fun putCell(col: Int, raw: String) {
            if (!sheetOpen || !acceptCells || col < 0) return
            if (col >= colLimit || budget.exhausted) {
                truncated = true
                if (budget.exhausted) throw SheetRowLimitException()
                return
            }
            while (currentRow.size <= col) currentRow.add("")
            currentRow[col] = budget.take(raw)
            if (budget.exhausted) {
                truncated = true
                throw SheetRowLimitException()
            }
        }
    }

    /**
     * Walks BIFF records without [org.apache.poi.hssf.record.SSTRecord].
     * POI's event factory materialises every shared string before the first cell.
     */
    private fun processXlsRecords(
        fs: POIFSFileSystem,
        listener: HSSFListener,
        reader: XlsEventReader,
    ) {
        val root = fs.root
        val entryName = InternalWorkbook.WORKBOOK_DIR_ENTRY_NAMES
            .firstOrNull { root.hasEntry(it) }
            ?: throw IllegalStateException("This .xls file has no workbook stream.")
        root.createDocumentInputStream(entryName).use { document ->
            val input = RecordInputStream(document)
            while (input.hasNextRecord()) {
                input.nextRecord()
                if (input.sid.toInt() == SSTRecord.sid.toInt()) {
                    val sst = readBoundedSst(input)
                    reader.sharedStrings = sst.values
                    reader.sstTruncated = sst.truncated
                    if (sst.truncated) reader.truncated = true
                    logStep(
                        "parseXLS:sst kept=${sst.values.size} truncated=${sst.truncated}",
                    )
                    continue
                }
                val created = RecordFactory.createRecord(input) ?: continue
                for (record in created) {
                    listener.processRecord(record)
                }
            }
        }
    }

    private data class SstLoad(val values: List<String>, val truncated: Boolean)

    private fun readBoundedSst(input: RecordInputStream): SstLoad {
        val total = input.readInt()
        val unique = input.readInt()
        logStep("parseXLS:sst header total=$total unique=$unique")
        if (total < 0 || unique < 0) throw SheetRowLimitException()
        val kept = ArrayList<String>(minOf(maxSstEntries, unique))
        var chars = 0
        var truncated = false
        var aborted = false
        val scratch = ByteArray(8192)
        var index = 0
        try {
            while (index < unique) {
                val keep = if (index < maxSstEntries && chars < maxSstChars) maxCellChars else 0
                val text = readSstString(input, keep, scratch)
                if (keep > 0) {
                    kept.add(text)
                    chars += text.length
                } else {
                    truncated = true
                }
                index++
            }
        } catch (e: SheetRowLimitException) {
            throw e
        } catch (e: RuntimeException) {
            Log.w(TAG, "Shared-string table stopped at $index: ${e.message}")
            truncated = true
            aborted = true
        } finally {
            drainRecord(input, scratch)
        }
        if (aborted) throw SheetRowLimitException()
        return SstLoad(kept, truncated)
    }

    private fun readSstString(input: RecordInputStream, keep: Int, scratch: ByteArray): String {
        val charCount = unsignedShort(input.readShort())
        val flags = input.readByte().toInt() and 0xFF
        val runCount = if (flags and 0x08 != 0) unsignedShort(input.readShort()) else 0
        val extLen = if (flags and 0x04 != 0) input.readInt() else 0
        if (runCount > 65_535 || extLen < 0) throw SheetRowLimitException()
        val compressed = flags and 0x01 == 0
        val text = readOrSkipChars(input, charCount, compressed, keep, scratch)
        var runsLeft = runCount
        while (runsLeft > 0) {
            input.readShort()
            input.readShort()
            runsLeft--
        }
        if (extLen > 0) skipLooseBytes(input, extLen, scratch)
        return text
    }

    /**
     * Mirrors RecordInputStream.readStringCommon, including the CONTINUE
     * compression flag, but only keeps [keep] characters.
     */
    private fun readOrSkipChars(
        input: RecordInputStream,
        count: Int,
        startCompressed: Boolean,
        keep: Int,
        scratch: ByteArray,
    ): String {
        val sb = if (keep > 0) StringBuilder(minOf(keep, 32)) else null
        var compressed = startCompressed
        var done = 0
        var continues = 0
        while (done < count) {
            val availChars = if (compressed) input.remaining() else input.remaining() / 2
            if (availChars <= 0) {
                if (input.remaining() > 0) skipExact(input, input.remaining(), scratch)
                if (!input.hasNextRecord() || input.getNextSid() != ContinueRecord.sid.toInt()) break
                input.nextRecord()
                val flag = input.readUByte()
                if (flag != 0 && flag != 1) throw SheetRowLimitException()
                compressed = flag == 0
                continues++
                if (continues > 100_000) throw SheetRowLimitException()
                continue
            }
            val take = minOf(availChars, count - done)
            val room = if (sb == null) 0 else keep - sb.length
            if (room > 0) {
                val copy = minOf(take, room)
                appendBiffChars(input, copy, compressed, sb!!)
                val rest = take - copy
                if (rest > 0) skipExact(input, if (compressed) rest else rest * 2, scratch)
            } else {
                skipExact(input, if (compressed) take else take * 2, scratch)
            }
            done += take
        }
        return sb?.toString() ?: ""
    }

    private fun appendBiffChars(
        input: RecordInputStream,
        count: Int,
        compressed: Boolean,
        sb: StringBuilder,
    ) {
        var left = count
        while (left > 0) {
            val ch = if (compressed) input.readUByte() else input.readShort().toInt() and 0xFFFF
            sb.append(ch.toChar())
            left--
        }
    }

    private fun skipExact(input: RecordInputStream, bytes: Int, scratch: ByteArray) {
        var left = bytes
        while (left > 0) {
            val n = minOf(left, input.remaining(), scratch.size)
            if (n <= 0) break
            input.readFully(scratch, 0, n)
            left -= n
        }
    }

    private fun skipLooseBytes(input: RecordInputStream, bytes: Int, scratch: ByteArray) {
        var left = bytes
        while (left > 0) {
            val rem = input.remaining()
            if (rem <= 0) {
                input.readByte()
                left--
                continue
            }
            val n = minOf(left, rem, scratch.size)
            input.readFully(scratch, 0, n)
            left -= n
        }
    }

    private fun drainRecord(input: RecordInputStream, scratch: ByteArray) {
        val left = input.remaining()
        if (left > 0) skipExact(input, left, scratch)
    }

    private fun unsignedShort(value: Short): Int {
        return if (value < 0) value + 65536 else value.toInt()
    }

    private class TextBudget(
        private val maxChars: Int,
        private val maxCells: Int,
        private val maxItemChars: Int,
    ) {
        private var used = 0
        private var cells = 0
        var exhausted = false
            private set

        fun take(raw: String?): String {
            if (exhausted || raw.isNullOrEmpty()) return ""
            if (cells >= maxCells || used >= maxChars) {
                exhausted = true
                return ""
            }
            var clipped = raw
            val room = maxChars - used
            if (clipped.length > maxItemChars) clipped = clipped.substring(0, maxItemChars)
            if (clipped.length > room) clipped = clipped.substring(0, room)
            used += clipped.length
            cells += 1
            if (used >= maxChars || cells >= maxCells) exhausted = true
            return clipped
        }
    }

    /** Stops a zip entry from being pulled fully into the XML parser. */
    private class CappedInputStream(
        private val source: InputStream,
        private val maxBytes: Long,
    ) : InputStream() {
        private var seen = 0L
        private var capChecked = false
        var hitCap = false
            private set

        override fun read(): Int {
            val buf = ByteArray(1)
            val n = read(buf, 0, 1)
            return if (n < 0) -1 else buf[0].toInt() and 0xFF
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (len <= 0) return 0
            if (seen >= maxBytes) return endOfCap()
            val allowed = minOf(len.toLong(), maxBytes - seen).toInt()
            val n = source.read(b, off, allowed)
            if (n > 0) seen += n
            return n
        }

        private fun endOfCap(): Int {
            if (!capChecked) {
                capChecked = true
                if (source.read() >= 0) hitCap = true
            }
            return -1
        }

        override fun close() {
            // The caller closes the package-part stream.
        }
    }
}
