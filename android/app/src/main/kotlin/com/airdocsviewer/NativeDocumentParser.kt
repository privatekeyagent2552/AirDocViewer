package com.airdocsviewer

import android.app.Activity
import android.util.Log
import io.flutter.plugin.common.MethodChannel
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
import org.apache.poi.hssf.record.MulBlankRecord
import org.apache.poi.hssf.record.MulRKRecord
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
import org.apache.poi.poifs.filesystem.DocumentEntry
import org.apache.poi.poifs.filesystem.POIFSFileSystem
import org.apache.poi.ss.usermodel.DataFormatter
import org.apache.poi.ss.util.CellReference
import org.apache.poi.util.IOUtils
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
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.nio.charset.Charset
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipOutputStream
import javax.xml.parsers.SAXParserFactory

class NativeDocumentParser(private val TAG: String) {

    /**
     * Hard caps for a full-workbook parse. The spreadsheet viewer does not use
     * that path. It calls [handleReadSheetWindow], which returns one rectangle
     * so later rows, columns, and sheets stay reachable.
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
    /** One on-screen rectangle. Callers cannot ask for a larger one. */
    private val windowRowsMax = 200
    private val windowColsMax = 30
    /** A single cell longer than this is cut. One huge cell must not fill the heap. */
    private val windowCellChars = 2_048
    /** A BIFF body above this is skipped. Normal cell records are a few kilobytes. */
    private val maxWindowRecordBytes = 1_048_576
    /** Small .doc files still use HWPF. Larger files stream a paragraph window. */
    private val maxDocBytes = 8L * 1024 * 1024
    /** Small .docx files still use XWPF when document.xml is under this. */
    private val maxDocxXmlBytes = 12L * 1024 * 1024
    private val maxDocxVisualBytes = 64L * 1024 * 1024
    private val maxCsvBytes = 8L * 1024 * 1024
    /**
     * One slide's drawing XML. The parser stops instead of building a DOM,
     * and ppt/media is never opened.
     */
    private val maxSlideXmlBytes = 768L * 1024
    /**
     * Bytes read from the PowerPoint Document stream. Picture bytes live in
     * a different OLE stream and are not read.
     */
    private val maxPptDocumentBytes = 8L * 1024 * 1024
    /** Text kept for Flutter. Three copies (slides, plain text, blocks) stay under a few MB. */
    private val maxPresentationChars = 400_000
    private val maxSlideChars = 12_000
    /**
     * One paged .ppt slide. The viewer asks for a single slide, so this does
     * not apply to the other slides and does not drop them.
     */
    private val maxPagedSlideChars = 100_000
    /** One picture inside the slide on screen. Larger pictures are placeholders. */
    private val maxOnePictureBytes = 2_500_000L
    /** Pictures copied for the current slide. The rest of ppt/media stays in the zip. */
    private val maxSlideMediaBytes = 8L * 1024 * 1024
    private val pptSlideXml = Regex("""(?:^|/)ppt/slides/slide(\d+)\.xml$""")

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
            deliverResult(result) { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.error(code, message, null) }
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
        } catch (t: Throwable) {
            // Includes OutOfMemoryError. The reply is a short sentence.
            // The stack stays in logcat, not on the Flutter screen.
            Log.e(TAG, "Parse error", t)
            logCauseChain("Parse error", t)
            replyError("PARSE_ERROR", failureMessage(t))
        }
    }

    /** Finish the platform reply on the UI thread before the worker keeps another document alive. */
    private fun deliverResult(result: MethodChannel.Result, block: () -> Unit) {
        val latch = CountDownLatch(1)
        try {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                try {
                    block()
                } catch (t: Throwable) {
                    Log.e(TAG, "Platform reply failed", t)
                    try {
                        result.error("PARSE_ERROR", failureMessage(t), null)
                    } catch (_: Throwable) {
                    }
                } finally {
                    latch.countDown()
                }
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Could not post platform reply", t)
            latch.countDown()
        }
        try {
            latch.await(60, TimeUnit.SECONDS)
        } catch (_: Throwable) {
        }
    }

    private fun failureMessage(t: Throwable): String {
        val text = t.message.orEmpty()
        val oom = t is OutOfMemoryError ||
            generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
        return if (oom || text.contains("too large", ignoreCase = true)) {
            "This file is too large to open completely on this device."
        } else {
            "This file could not be opened."
        }
    }

    /**
     * One .pptx slide for the WebView. Opens the zip, copies that slide's XML
     * and only the pictures it references, then closes the zip.
     */
    fun handleReadPptxSlide(
        filePath: String?,
        slideIndex: Int?,
        mediaDir: String?,
        packagePath: String?,
        result: MethodChannel.Result,
        activity: Activity,
    ) {
        var replied = false
        fun replySuccess(data: Any?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.error(code, message, null) }
        }
        try {
            if (activity.isDestroyed) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            if (filePath.isNullOrBlank() || mediaDir.isNullOrBlank() || packagePath.isNullOrBlank()) {
                replyError("INVALID_ARGS", "This file could not be opened.")
                return
            }
            val source = File(filePath)
            val pictures = File(mediaDir)
            val pkg = File(packagePath)
            if (!source.isFile || !isInsideCache(activity, pictures) || !isInsideCache(activity, pkg)) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            replySuccess(readPptxSlidePage(source, slideIndex ?: 0, pictures, pkg))
        } catch (t: Throwable) {
            Log.e(TAG, "readPptxSlide failed", t)
            replyError("PARSE_ERROR", failureMessage(t))
        }
    }

    /**
     * One .ppt slide of text. Walks the PowerPoint Document stream and keeps
     * only the requested slide. Does not construct HSLFSlideShow and does not
     * open the Pictures stream.
     */
    fun handleReadPptSlide(
        filePath: String?,
        slideIndex: Int?,
        result: MethodChannel.Result,
        activity: Activity,
    ) {
        var replied = false
        fun replySuccess(data: Any?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.error(code, message, null) }
        }
        try {
            if (activity.isDestroyed || filePath.isNullOrBlank()) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            val source = File(filePath)
            if (!source.isFile) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            replySuccess(readPptSlidePage(source, slideIndex ?: 0))
        } catch (t: Throwable) {
            Log.e(TAG, "readPptSlide failed", t)
            replyError("PARSE_ERROR", failureMessage(t))
        }
    }

    /**
     * One rectangle of one sheet. Does not build a workbook, a stylesheet, or
     * a shared-string table for the rest of the file.
     */
    fun handleReadSheetWindow(
        filePath: String?,
        format: String?,
        sheetIndex: Int?,
        startRow: Int?,
        rowCount: Int?,
        startCol: Int?,
        colCount: Int?,
        result: MethodChannel.Result,
        activity: Activity,
    ) {
        var replied = false
        fun replySuccess(data: Any?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.error(code, message, null) }
        }
        try {
            configurePoiLimits()
            if (activity.isDestroyed || filePath.isNullOrBlank() || format.isNullOrBlank()) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            val source = File(filePath)
            if (!source.isFile) {
                replyError("PARSE_ERROR", "This file could not be opened.")
                return
            }
            val rows = (rowCount ?: windowRowsMax).coerceIn(1, windowRowsMax)
            val cols = (colCount ?: windowColsMax).coerceIn(1, windowColsMax)
            val sheet = (sheetIndex ?: 0).coerceAtLeast(0)
            val row = (startRow ?: 0).coerceAtLeast(0)
            val col = (startCol ?: 0).coerceAtLeast(0)
            val started = System.currentTimeMillis()
            val data = when (format.uppercase()) {
                "XLSX" -> readXlsxWindow(source, sheet, row, rows, col, cols)
                "XLS" -> readXlsWindow(source, sheet, row, rows, col, cols)
                else -> throw IllegalArgumentException("Unsupported format")
            }
            logStep(
                "readSheetWindow ${format.uppercase()} sheet=$sheet " +
                    "rows=$row+$rows cols=$col+$cols ${System.currentTimeMillis() - started}ms",
            )
            replySuccess(data)
        } catch (t: Throwable) {
            Log.e(TAG, "readSheetWindow failed", t)
            replyError("PARSE_ERROR", failureMessage(t))
        }
    }

    /**
     * One window of Word paragraphs. Does not build XWPFDocument or HWPFDocument.
     * A failed window is a normal result so the next window can still be opened.
     */
    fun handleReadWordWindow(
        filePath: String?,
        format: String?,
        start: Int?,
        result: MethodChannel.Result,
        activity: Activity,
    ) {
        var replied = false
        fun replySuccess(data: Any?) {
            if (replied) return
            replied = true
            deliverResult(result) { result.success(data) }
        }
        val safeStart = (start ?: 0).coerceAtLeast(0)
        try {
            if (activity.isDestroyed || filePath.isNullOrBlank() || format.isNullOrBlank()) {
                replySuccess(wordWindowFailure(safeStart))
                return
            }
            val source = File(filePath)
            if (!source.isFile) {
                replySuccess(wordWindowFailure(safeStart))
                return
            }
            val started = System.currentTimeMillis()
            val data = WordWindowReader(TAG).read(source, format, safeStart)
            logStep(
                "readWordWindow ${format.uppercase()} start=$safeStart " +
                    "${System.currentTimeMillis() - started}ms",
            )
            replySuccess(data)
        } catch (t: Throwable) {
            Log.e(TAG, "readWordWindow failed", t)
            replySuccess(wordWindowFailure(safeStart))
        }
    }

    private fun wordWindowFailure(start: Int): Map<String, Any> {
        return mapOf(
            "start" to start,
            "blocks" to emptyList<Map<String, Any>>(),
            "hasMore" to true,
            "failed" to true,
        )
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
        val warnings = linkedSetOf(
            "Presentation shows slide text, headings, and detected bullets without original layout or images.",
        )
        val extract = SlideExtract()
        try {
            // HSLFSlideShow / XMLSlideShow build the whole deck, including every
            // picture, before a slide cap can run. Read text records only.
            if (normalized == "PPT") {
                readPptText(file, extract)
            } else {
                readPptxText(file, extract)
            }
        } catch (_: OutOfMemoryError) {
            extract.truncated = true
            warnings.add("Opened a partial copy because this presentation ran out of memory.")
            Log.e(TAG, "parsePresentation out of memory")
        }
        warnings.addAll(extract.warnings)
        if (extract.truncated) {
            warnings.add(
                "Showing the first $maxSlides slides so this presentation fits in memory.",
            )
        }
        val texts = extract.chosenTexts()
        logStep(
            "parsePresentation:done slides=${texts.size} truncated=${extract.truncated}",
        )
        return presentationPayload(filePath, format, texts, warnings)
    }

    /**
     * Binary .ppt text from the PowerPoint Document stream.
     * POIFS is read-only and closed here. The Pictures stream is never opened,
     * so HSLFSlideShow (which has no File constructor and loads every picture)
     * is not used.
     */
    private fun readPptText(file: File, extract: SlideExtract) {
        val fs = POIFSFileSystem(file, true)
        try {
            val root = fs.root
            if (!root.hasEntry("PowerPoint Document")) {
                extract.warnings.add("This .ppt file has no readable slide text.")
                return
            }
            val stream = root.createDocumentInputStream("PowerPoint Document")
            try {
                val capped = CappedInputStream(stream, maxPptDocumentBytes)
                walkPptRecords(capped, extract, Long.MAX_VALUE)
                if (capped.hitCap) extract.truncated = true
            } finally {
                stream.close()
            }
        } finally {
            fs.close()
        }
    }

    private fun readPptxText(file: File, extract: SlideExtract) {
        ZipFile(file).use { zip ->
            val names = ArrayList<String>()
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val name = entries.nextElement().name.replace('\\', '/')
                if (pptSlideXml.containsMatchIn(name)) {
                    names.add(name)
                    if (names.size > 5000) {
                        extract.truncated = true
                        break
                    }
                }
            }
            names.sortBy { pptSlideXml.find(it)?.groupValues?.get(1)?.toIntOrNull() ?: 0 }
            if (names.size > maxSlides) extract.truncated = true
            val limit = minOf(names.size, maxSlides)
            for (i in 0 until limit) {
                if (extract.stop) {
                    extract.truncated = true
                    break
                }
                val entry = zip.getEntry(names[i]) ?: continue
                extract.slides.add(StringBuilder())
                zip.getInputStream(entry).use { raw ->
                    val capped = CappedInputStream(raw, maxSlideXmlBytes)
                    try {
                        pullSlideText(capped, extract)
                    } catch (_: OutOfMemoryError) {
                        extract.truncated = true
                        extract.stop = true
                        Log.e(TAG, "Slide XML ran out of memory")
                    } catch (t: Exception) {
                        extract.truncated = true
                        Log.w(TAG, "Skip slide XML ${names[i]}: ${t.message}")
                    }
                    if (capped.hitCap) extract.truncated = true
                }
            }
        }
    }

    private fun pullSlideText(input: InputStream, extract: SlideExtract) {
        val factory = XmlPullParserFactory.newInstance()
        factory.isNamespaceAware = true
        val parser = factory.newPullParser()
        parser.setInput(input, "UTF-8")
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT && !extract.stop) {
            if (event == XmlPullParser.START_TAG && parser.name == "t") {
                extract.appendCurrent(parser.nextText())
            }
            event = parser.next()
        }
    }

    private fun walkPptRecords(input: InputStream, extract: SlideExtract, region: Long) {
        val bounded = region != Long.MAX_VALUE
        var left = if (bounded) region else Long.MAX_VALUE
        val header = ByteArray(8)
        while ((!bounded || left >= 8L) && !extract.stop) {
            if (!readFully(input, header)) {
                extract.truncated = true
                extract.stop = true
                return
            }
            if (bounded) left -= 8
            val info = u16le(header, 0)
            val type = u16le(header, 2)
            val length = u32le(header, 4)
            if (bounded && length > left) {
                extract.truncated = true
                extract.stop = true
                return
            }
            val container = (info and 0xF) == 0xF
            if (container) {
                if (!extract.paging &&
                    type == RT_SLIDE &&
                    extract.slideDepth == 0 &&
                    extract.slides.size >= maxSlides
                ) {
                    extract.truncated = true
                    extract.stop = true
                    return
                }
                extract.onContainer(type, true)
                if (!extract.stop) {
                    walkPptRecords(input, extract, length)
                }
                extract.onContainer(type, false)
            } else if (type == RT_TEXT_CHARS || type == RT_TEXT_BYTES) {
                val takeCap = if (extract.paging) {
                    maxPagedSlideChars.toLong() * 4L
                } else {
                    32L * 1024L
                }
                val take = minOf(length, takeCap)
                val buf = ByteArray(take.toInt())
                if (take > 0 && !readFully(input, buf)) {
                    extract.truncated = true
                    extract.stop = true
                    return
                }
                val rest = length - take
                if (rest > 0) {
                    if (!extract.paging) extract.truncated = true
                    if (!discardStream(input, rest)) {
                        extract.stop = true
                        return
                    }
                }
                extract.appendAtom(type, buf)
            } else {
                if (type == RT_SLIDE_PERSIST) extract.onPersist()
                if (length > 0 && !discardStream(input, length)) {
                    extract.truncated = true
                    extract.stop = true
                    return
                }
            }
            if (bounded) {
                left -= length
                if (left < 0L) return
            }
        }
        if (bounded && left > 0L && !extract.stop) {
            if (!discardStream(input, left)) {
                extract.truncated = true
                extract.stop = true
            }
        }
    }

    private fun readFully(input: InputStream, buf: ByteArray, len: Int = buf.size): Boolean {
        var off = 0
        while (off < len) {
            val n = input.read(buf, off, len - off)
            if (n <= 0) return false
            off += n
        }
        return true
    }

    private fun discardStream(input: InputStream, bytes: Long): Boolean {
        var left = bytes
        val scratch = ByteArray(8192)
        while (left > 0L) {
            val n = input.read(scratch, 0, minOf(scratch.size.toLong(), left).toInt())
            if (n <= 0) return false
            left -= n
        }
        return true
    }

    private fun u16le(b: ByteArray, off: Int): Int {
        return (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8)
    }

    private fun u32le(b: ByteArray, off: Int): Long {
        return (b[off].toLong() and 0xFF) or
            ((b[off + 1].toLong() and 0xFF) shl 8) or
            ((b[off + 2].toLong() and 0xFF) shl 16) or
            ((b[off + 3].toLong() and 0xFF) shl 24)
    }

    private fun presentationPayload(
        filePath: String,
        format: String,
        slideTexts: List<String>,
        warnings: Collection<String>,
    ): Map<String, Any> {
        val slides = mutableListOf<Map<String, Any>>()
        val blocks = mutableListOf<Map<String, Any>>()
        val allText = StringBuilder()
        slideTexts.forEachIndexed { i, raw ->
            val text = raw.trimEnd()
            val number = i + 1
            slides.add(mapOf("slideNumber" to number, "text" to text))
            if (text.isNotEmpty() && allText.length < maxPresentationChars) {
                if (allText.isNotEmpty()) allText.append("\n\n")
                allText.append("[Slide ").append(number).append("]\n")
                val room = maxPresentationChars - allText.length
                allText.append(if (text.length > room) text.substring(0, room) else text)
            }
            if (blocks.size < maxDocBlocks) {
                blocks.add(
                    mapOf(
                        "type" to "paragraph",
                        "inlines" to listOf(
                            mapOf(
                                "type" to "text",
                                "text" to "Slide $number",
                                "style" to mapOf("bold" to true, "fontSize" to 16.0),
                            ),
                        ),
                    ),
                )
            }
            for (line in text.split(Regex("\\r\\n|\\r|\\n"))) {
                if (blocks.size >= maxDocBlocks) break
                val trimmed = line.trimEnd()
                if (trimmed.isBlank()) continue
                val bullet = trimmed.startsWith("•") ||
                    trimmed.startsWith("- ") ||
                    trimmed.startsWith("* ") ||
                    trimmed.startsWith("–") ||
                    Regex("^\\d+[.)]\\s+").containsMatchIn(trimmed)
                val cleaned = trimmed
                    .removePrefix("•")
                    .removePrefix("* ")
                    .removePrefix("- ")
                    .removePrefix("–")
                    .replaceFirst(Regex("^\\d+[.)]\\s+"), "")
                    .trim()
                val block = mutableMapOf<String, Any>(
                    "type" to "paragraph",
                    "inlines" to listOf(
                        mapOf(
                            "type" to "text",
                            "text" to cleaned.ifBlank { trimmed },
                            "style" to emptyMap<String, Any>(),
                        ),
                    ),
                )
                if (bullet) {
                    block["listLevel"] = 0
                    block["listKind"] =
                        if (Regex("^\\d+[.)]").containsMatchIn(trimmed)) "decimal" else "bullet"
                }
                blocks.add(block)
            }
            if (blocks.size < maxDocBlocks) {
                blocks.add(mapOf("type" to "spacer", "height" to 20.0, "isPageBreak" to true))
            }
        }
        val plain = OfficeGlyphSanitizer.sanitize(allText.toString().trim())
        val wordCount = plain.split(Regex("\\s+")).count { it.isNotBlank() }
        val lineCount = plain.split(Regex("\\r\\n|\\r|\\n")).count { it.isNotBlank() }.coerceAtLeast(1)
        Log.w(TAG, "Presentation parse OK format=$format slides=${slides.size} chars=${plain.length}")
        return mapOf(
            "textContent" to plain,
            "plainTextContent" to plain,
            "slides" to slides,
            "slideCount" to slides.size.coerceAtLeast(if (plain.isNotEmpty()) 1 else 0),
            "documentBlocks" to blocks,
            "parseWarnings" to warnings.toList(),
            "fidelityLevel" to if (plain.isNotEmpty()) "partial" else "plainText",
            "wordCount" to wordCount,
            "lineCount" to lineCount,
            "format" to format,
            "filePath" to filePath,
        )
    }

    private inner class SlideExtract {
        val slides = mutableListOf<StringBuilder>()
        val outline = mutableListOf<StringBuilder>()
        val warnings = linkedSetOf<String>()
        var truncated = false
        var stop = false
        var slideDepth = 0
        var outlineDepth = 0
        var paging = false
        var pageTarget = 0
        var slideOrdinal = 0
        var outlineOrdinal = 0
        var captureSlide = false
        var captureOutline = false
        val pagedSlide = StringBuilder()
        val pagedOutline = StringBuilder()
        private var totalChars = 0

        fun onContainer(type: Int, start: Boolean) {
            if (type == RT_SLIDE) {
                if (start) {
                    slideDepth++
                    if (slideDepth == 1) {
                        if (paging) {
                            captureSlide = slideOrdinal == pageTarget
                            slideOrdinal++
                        } else {
                            slides.add(StringBuilder())
                        }
                    }
                } else if (slideDepth > 0) {
                    slideDepth--
                    if (paging && slideDepth == 0) captureSlide = false
                }
            } else if (type == RT_SLIDE_LIST) {
                if (start) outlineDepth++ else if (outlineDepth > 0) outlineDepth--
            }
        }

        fun onPersist() {
            if (outlineDepth == 0 || slideDepth != 0) return
            if (paging) {
                captureOutline = outlineOrdinal == pageTarget
                outlineOrdinal++
                return
            }
            if (outline.size >= maxSlides) {
                truncated = true
                stop = true
                return
            }
            outline.add(StringBuilder())
        }

        fun appendAtom(type: Int, bytes: ByteArray) {
            if (stop || bytes.isEmpty()) return
            val raw = if (type == RT_TEXT_CHARS) {
                String(bytes, Charsets.UTF_16LE)
            } else {
                String(bytes, Charset.forName("windows-1252"))
            }
            if (paging) {
                val paged = when {
                    slideDepth > 0 && captureSlide -> pagedSlide
                    slideDepth == 0 && outlineDepth > 0 && captureOutline -> pagedOutline
                    else -> return
                }
                appendPaged(paged, raw)
                return
            }
            val target = when {
                slideDepth > 0 && slides.isNotEmpty() -> slides.last()
                outlineDepth > 0 -> {
                    if (outline.isEmpty()) outline.add(StringBuilder())
                    outline.last()
                }
                else -> return
            }
            appendTo(target, raw)
        }

        fun appendCurrent(raw: String?) {
            if (stop || slides.isEmpty()) return
            appendTo(slides.last(), raw ?: return)
        }

        fun appendPaged(target: StringBuilder, raw: String) {
            val cleaned = OfficeGlyphSanitizer.sanitize(
                raw.replace('\u0000', ' ').trim(),
            )
            if (cleaned.isEmpty() || target.length >= maxPagedSlideChars) return
            val room = maxPagedSlideChars - target.length
            val piece = if (cleaned.length > room) cleaned.substring(0, room) else cleaned
            if (target.isNotEmpty()) target.append('\n')
            target.append(piece)
        }

        private fun appendTo(target: StringBuilder, raw: String) {
            val cleaned = OfficeGlyphSanitizer.sanitize(
                raw.replace('\u0000', ' ').trim(),
            )
            if (cleaned.isEmpty()) return
            if (target.length >= maxSlideChars) {
                truncated = true
                return
            }
            val room = minOf(maxSlideChars - target.length, maxPresentationChars - totalChars)
            if (room <= 0) {
                truncated = true
                if (totalChars >= maxPresentationChars) stop = true
                return
            }
            val piece = if (cleaned.length > room) cleaned.substring(0, room) else cleaned
            if (target.isNotEmpty()) target.append('\n')
            target.append(piece)
            totalChars += piece.length
            if (piece.length < cleaned.length) truncated = true
            if (totalChars >= maxPresentationChars) stop = true
        }

        fun chosenTexts(): List<String> {
            if (slides.isNotEmpty()) return slides.map { it.toString().trimEnd() }
            return outline.map { it.toString().trimEnd() }.filter { it.isNotBlank() }
        }
    }

    companion object {
        private const val RT_SLIDE = 1006
        private const val RT_SLIDE_PERSIST = 1011
        private const val RT_TEXT_CHARS = 4000
        private const val RT_TEXT_BYTES = 4008
        private const val RT_SLIDE_LIST = 4080
    }

    private fun readPptSlidePage(file: File, index: Int): Map<String, Any> {
        val extract = SlideExtract()
        extract.paging = true
        extract.pageTarget = index.coerceAtLeast(0)
        val fs = POIFSFileSystem(file, true)
        try {
            val root = fs.root
            if (!root.hasEntry("PowerPoint Document")) {
                return mapOf("index" to 0, "slideCount" to 0, "text" to "")
            }
            val entry = root.getEntry("PowerPoint Document")
            if (entry !is DocumentEntry) {
                return mapOf("index" to 0, "slideCount" to 0, "text" to "")
            }
            val stream = root.createDocumentInputStream("PowerPoint Document")
            try {
                val declared = entry.size.toLong()
                val region = if (declared > 0L) declared else Long.MAX_VALUE
                walkPptRecords(stream, extract, region)
            } finally {
                stream.close()
            }
        } finally {
            fs.close()
        }
        val count = if (extract.slideOrdinal > 0) extract.slideOrdinal else extract.outlineOrdinal
        val text = if (extract.slideOrdinal > 0) {
            extract.pagedSlide.toString().trimEnd()
        } else {
            extract.pagedOutline.toString().trimEnd()
        }
        val safe = if (count <= 0) 0 else index.coerceIn(0, count - 1)
        logStep("readPptSlidePage index=$safe count=$count chars=${if (safe == index.coerceAtLeast(0)) text.length else 0}")
        return mapOf(
            "index" to safe,
            "slideCount" to count,
            "text" to if (count > 0 && index.coerceAtLeast(0) == safe) text else "",
        )
    }

    private fun readPptxSlidePage(
        file: File,
        index: Int,
        mediaDir: File,
        packageFile: File,
    ): Map<String, Any> {
        ZipFile(file).use { zip ->
            val names = ZipNameIndex(zip)
            val slides = names.originals.filter { pptSlideXml.containsMatchIn(it) }
                .sortedBy { pptSlideXml.find(it)?.groupValues?.get(1)?.toIntOrNull() ?: 0 }
            if (slides.isEmpty()) {
                logStep("readPptxSlidePage no slides")
                return slidePageResult(0, 0, false, emptyList())
            }
            val safe = index.coerceIn(0, slides.lastIndex)
            return try {
                packageOneSlide(zip, names, slides, safe, mediaDir, packageFile)
            } catch (t: Throwable) {
                Log.e(TAG, "Slide ${safe + 1} could not be packaged", t)
                clearMediaDir(mediaDir)
                packageFile.delete()
                slidePageResult(
                    slides.size,
                    safe,
                    true,
                    emptyList(),
                    t.message ?: "package failed",
                )
            }
        }
    }

    private fun packageOneSlide(
        zip: ZipFile,
        names: ZipNameIndex,
        slides: List<String>,
        safe: Int,
        mediaDir: File,
        packageFile: File,
    ): Map<String, Any> {
        // One slide only. Higher than the 768 KB text-extract cap so a dense
        // slide still draws. The bytes are the current slide package, then discarded.
        val slideCap = 8L * 1024 * 1024
        val partCap = 4L * 1024 * 1024
        val slideName = slides[safe]
        val slideBytes = readZipCapped(zip, names, slideName, slideCap)
        if (slideBytes == null) {
            val reason = "slide xml missing or over $slideCap bytes"
            Log.w(TAG, "readPptxSlidePage slide ${safe + 1} $reason")
            clearMediaDir(mediaDir)
            return slidePageResult(slides.size, safe, true, emptyList(), reason)
        }
        clearMediaDir(mediaDir)
        packageFile.parentFile?.mkdirs()
        if (packageFile.exists()) packageFile.delete()

        val images = ArrayList<Pair<String, String>>()
        val slideRelsName = relsPathFor(slideName)
        val slideRels = readZipCapped(zip, names, slideRelsName, partCap)
        val slideSpecial = harvestRels(slideRels, slideName, images)
        val layoutName = slideSpecial["layout"]
        val layoutBytes = layoutName?.let { readZipCapped(zip, names, it, partCap) }
        val layoutRelsName = layoutName?.let { relsPathFor(it) }
        val layoutRels = layoutRelsName?.let { readZipCapped(zip, names, it, partCap) }
        val layoutSpecial = harvestRels(layoutRels, layoutName ?: slideName, images)
        val masterName = layoutSpecial["master"]
        val masterBytes = masterName?.let { readZipCapped(zip, names, it, partCap) }
        val masterRelsName = masterName?.let { relsPathFor(it) }
        val masterRels = masterRelsName?.let { readZipCapped(zip, names, it, partCap) }
        val masterSpecial = harvestRels(masterRels, masterName ?: slideName, images)
        val themeName = masterSpecial["theme"]
        val themeBytes = themeName?.let { readZipCapped(zip, names, it, partCap) }
        val themeRelsName = themeName?.let { relsPathFor(it) }
        val themeRels = themeRelsName?.let { readZipCapped(zip, names, it, partCap) }
        harvestRels(themeRels, themeName ?: slideName, images)
        if (layoutName != null && layoutBytes == null) {
            Log.i(TAG, "Slide layout left out of package: $layoutName")
        }
        if (masterName != null && masterBytes == null) {
            Log.i(TAG, "Slide master left out of package: $masterName")
        }
        if (themeName != null && themeBytes == null) {
            Log.i(TAG, "Slide theme left out of package: $themeName")
        }

        val media = copySlidePictures(zip, names, images, mediaDir)
        // sldSz is a short tag. The rest of a huge presentation.xml (every
        // slide id, default text styles) stays out when it exceeds partCap.
        val rawPresentation = readZipCapped(zip, names, "ppt/presentation.xml", partCap)
        val slideSize = slideSizeFrom(rawPresentation, zip, names)
        ZipOutputStream(BufferedOutputStream(FileOutputStream(packageFile))).use { out ->
            fun put(name: String, bytes: ByteArray) {
                out.putNextEntry(ZipEntry(name))
                out.write(bytes)
                out.closeEntry()
            }
            put("ppt/presentation.xml", presentationWithSize(rawPresentation, slideSize))
            put(
                "docProps/app.xml",
                readZipCapped(zip, names, "docProps/app.xml", 64L * 1024) ?: appStub(),
            )
            val table = readZipCapped(zip, names, "ppt/tableStyles.xml", partCap)
            if (table != null) put("ppt/tableStyles.xml", table)
            put(slideName, slideBytes)
            if (slideRels != null) put(slideRelsName, slideRels)
            if (layoutName != null && layoutBytes != null) put(layoutName, layoutBytes)
            if (layoutRelsName != null && layoutRels != null) put(layoutRelsName, layoutRels)
            if (masterName != null && masterBytes != null) put(masterName, masterBytes)
            if (masterRelsName != null && masterRels != null) put(masterRelsName, masterRels)
            if (themeName != null && themeBytes != null) put(themeName, themeBytes)
            if (themeRelsName != null && themeRels != null) put(themeRelsName, themeRels)
            val contentParts = ArrayList<Pair<String, String>>()
            contentParts.add(
                slideName to
                    "application/vnd.openxmlformats-officedocument.presentationml.slide+xml",
            )
            if (layoutName != null && layoutBytes != null) {
                contentParts.add(
                    layoutName to
                        "application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml",
                )
            }
            if (masterName != null && masterBytes != null) {
                contentParts.add(
                    masterName to
                        "application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml",
                )
            }
            if (themeName != null && themeBytes != null) {
                contentParts.add(
                    themeName to
                        "application/vnd.openxmlformats-officedocument.theme+xml",
                )
            }
            contentParts.add(
                "ppt/presentation.xml" to
                    "application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
            )
            put("[Content_Types].xml", contentTypesFor(contentParts))
        }
        logStep(
            "readPptxSlidePage slide ${safe + 1}/${slides.size} " +
                "xml=${slideBytes.size} pictures=${media.size} " +
                "sldSz cx=${slideSize.cx} cy=${slideSize.cy} type=${slideSize.type}",
        )
        return slidePageResult(slides.size, safe, false, media)
    }

    private fun slidePageResult(
        count: Int,
        index: Int,
        undrawable: Boolean,
        media: List<Map<String, String>>,
        reason: String = "",
    ): Map<String, Any> {
        val result = mutableMapOf<String, Any>(
            "slideCount" to count,
            "index" to index,
            "undrawable" to undrawable,
            "media" to media,
        )
        if (reason.isNotEmpty()) result["reason"] = reason
        return result
    }

    private fun copySlidePictures(
        zip: ZipFile,
        names: ZipNameIndex,
        images: List<Pair<String, String>>,
        mediaDir: File,
    ): List<Map<String, String>> {
        if (!mediaDir.isDirectory && !mediaDir.mkdirs()) return emptyList()
        val copied = HashMap<String, String>()
        val media = ArrayList<Map<String, String>>()
        var used = 0L
        for ((jsKey, resolved) in images) {
            if (resolved.endsWith(".xml", ignoreCase = true)) continue
            if (isVideoPart(resolved) || isVideoPart(jsKey)) {
                Log.i(TAG, "Slide video placeholder, not loaded: $resolved")
                continue
            }
            val existing = copied[resolved]
            if (existing != null) {
                media.add(mapOf("zipPath" to jsKey, "file" to existing))
                continue
            }
            if (used >= maxSlideMediaBytes) {
                Log.i(TAG, "Slide picture placeholder, media budget full: $resolved")
                continue
            }
            val raw = names.lookup(resolved) ?: continue
            val entry = zip.getEntry(raw) ?: continue
            val room = maxSlideMediaBytes - used
            val cap = minOf(maxOnePictureBytes, room)
            val declared = entry.size
            if (declared > cap) {
                Log.i(TAG, "Slide picture placeholder over $cap bytes: $resolved")
                continue
            }
            val ext = safePictureExt(resolved)
            val fileName = "m${copied.size}.$ext"
            val dest = File(mediaDir, fileName)
            val written = try {
                zip.getInputStream(entry).use { copyCapped(it, dest, cap) }
            } catch (_: OutOfMemoryError) {
                dest.delete()
                -1L
            }
            if (written < 0L) {
                Log.i(TAG, "Slide picture placeholder, copy stopped: $resolved")
                continue
            }
            used += written
            copied[resolved] = fileName
            media.add(mapOf("zipPath" to jsKey, "file" to fileName))
            if (jsKey != resolved) {
                media.add(mapOf("zipPath" to resolved, "file" to fileName))
            }
        }
        return media
    }

    private fun copyCapped(input: InputStream, dest: File, cap: Long): Long {
        var out: FileOutputStream? = null
        return try {
            out = FileOutputStream(dest)
            val stream = out ?: return -1L
            val buf = ByteArray(8192)
            var total = 0L
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                if (total + n > cap) {
                    stream.close()
                    out = null
                    dest.delete()
                    return -1L
                }
                stream.write(buf, 0, n)
                total += n
            }
            total
        } catch (_: OutOfMemoryError) {
            try {
                out?.close()
            } catch (_: Throwable) {
            }
            out = null
            dest.delete()
            -1L
        } catch (t: Exception) {
            Log.w(TAG, "Skip picture ${dest.name}: ${t.message}")
            try {
                out?.close()
            } catch (_: Throwable) {
            }
            out = null
            dest.delete()
            -1L
        } finally {
            try {
                out?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun readZipCapped(
        zip: ZipFile,
        names: ZipNameIndex,
        logical: String,
        cap: Long,
    ): ByteArray? {
        val raw = names.lookup(logical) ?: return null
        val entry = zip.getEntry(raw) ?: return null
        if (entry.size > cap) return null
        zip.getInputStream(entry).use { input ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            var total = 0L
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                total += n
                if (total > cap) return null
                out.write(buf, 0, n)
            }
            return out.toByteArray()
        }
    }

    private fun harvestRels(
        rels: ByteArray?,
        basePart: String,
        images: MutableList<Pair<String, String>>,
    ): Map<String, String> {
        val specials = HashMap<String, String>()
        if (rels == null || rels.isEmpty()) return specials
        for (rel in parseRels(rels)) {
            if (rel.external) continue
            val resolved = resolveZipPath(basePart, rel.target) ?: continue
            when (relKind(rel.type)) {
                "image" -> images.add(jsZipKey(rel.target) to resolved)
                "layout", "master", "theme" ->
                    if (!specials.containsKey(relKind(rel.type))) {
                        specials[relKind(rel.type)] = resolved
                    }
                else -> Unit
            }
        }
        return specials
    }

    private fun relKind(type: String): String {
        val t = type.lowercase()
        return when {
            t.endsWith("/slidelayout") -> "layout"
            t.endsWith("/slidemaster") -> "master"
            t.endsWith("/theme") -> "theme"
            t.endsWith("/image") || t.endsWith("/hdphoto") -> "image"
            else -> "skip"
        }
    }

    private data class SlideRel(
        val type: String,
        val target: String,
        val external: Boolean,
    )

    private fun parseRels(bytes: ByteArray): List<SlideRel> {
        val factory = XmlPullParserFactory.newInstance()
        factory.isNamespaceAware = false
        val parser = factory.newPullParser()
        parser.setInput(bytes.inputStream(), "UTF-8")
        val out = ArrayList<SlideRel>()
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            if (event == XmlPullParser.START_TAG && parser.name.endsWith("Relationship")) {
                val type = parser.getAttributeValue(null, "Type").orEmpty()
                val target = parser.getAttributeValue(null, "Target").orEmpty()
                val mode = parser.getAttributeValue(null, "TargetMode").orEmpty()
                if (target.isNotEmpty() && !target.contains(':')) {
                    out.add(SlideRel(type, target, mode.equals("External", ignoreCase = true)))
                }
            }
            event = parser.next()
        }
        return out
    }

    private fun resolveZipPath(basePart: String, target: String): String? {
        val clean = target.replace('\\', '/').trim()
        if (clean.isEmpty() || clean.contains(':') || clean.startsWith("//")) return null
        if (clean.startsWith("/")) {
            val absolute = clean.trimStart('/')
            return if (absolute.contains("..")) null else absolute
        }
        val baseDir = basePart.substringBeforeLast('/', "")
        val stack = ArrayList<String>()
        if (baseDir.isNotEmpty()) {
            for (seg in baseDir.split('/')) {
                if (seg.isNotEmpty() && seg != ".") stack.add(seg)
            }
        }
        for (seg in clean.split('/')) {
            when (seg) {
                "", "." -> Unit
                ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
                else -> stack.add(seg)
            }
        }
        return stack.joinToString("/")
    }

    /**
     * Path pptxjs looks up after normalizing a relationship target.
     * Absolute targets (`/ppt/media/...`) and `../media/...` both become
     * `ppt/media/...`, which is also the name stored in the one-slide package.
     */
    private fun jsZipKey(target: String): String {
        var t = target.replace('\\', '/').trim()
        if (t.startsWith("/")) t = t.removePrefix("/")
        val dot = t.indexOf("../")
        if (dot >= 0) {
            t = t.substring(0, dot) + "ppt/" + t.substring(dot + 3)
        }
        val stack = ArrayList<String>()
        for (seg in t.split('/')) {
            when (seg) {
                "", "." -> Unit
                ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.lastIndex)
                else -> stack.add(seg)
            }
        }
        return stack.joinToString("/")
    }

    private fun relsPathFor(part: String): String {
        val slash = part.lastIndexOf('/')
        val dir = if (slash < 0) "_rels" else part.substring(0, slash) + "/_rels"
        val file = if (slash < 0) part else part.substring(slash + 1)
        return "$dir/$file.rels"
    }

    private fun safePictureExt(name: String): String {
        val ext = name.substringAfterLast('.', "bin")
            .lowercase()
            .filter { it.isLetterOrDigit() }
            .take(4)
        return if (ext.isEmpty()) "bin" else ext
    }

    private fun contentTypesFor(parts: List<Pair<String, String>>): ByteArray {
        val body = StringBuilder()
        body.append("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>""")
        body.append("""<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">""")
        body.append(
            """<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>""",
        )
        body.append("""<Default Extension="xml" ContentType="application/xml"/>""")
        for ((name, type) in parts) {
            val part = name.removePrefix("/").replace("&", "&amp;")
            body.append("""<Override PartName="/$part" ContentType="$type"/>""")
        }
        body.append("</Types>")
        return body.toString().toByteArray(Charsets.UTF_8)
    }

    private data class AppliedSlideSize(val cx: Long, val cy: Long, val type: String)

    /** Widescreen 16:9, the size PowerPoint writes when type is omitted. */
    private fun defaultSlideSize(): AppliedSlideSize {
        return AppliedSlideSize(12_192_000L, 6_858_000L, "screen16x9")
    }

    private val sldSzElement = Regex(
        """<(?:[A-Za-z_][\w.-]*:)?sldSz\b[^<>]*/>|<(?:[A-Za-z_][\w.-]*:)?sldSz\b[^<>]*>\s*</(?:[A-Za-z_][\w.-]*:)?sldSz>""",
        RegexOption.IGNORE_CASE,
    )

    private fun slideSizeFrom(
        presentation: ByteArray?,
        zip: ZipFile,
        names: ZipNameIndex,
    ): AppliedSlideSize {
        if (presentation != null) {
            return sizeFromPresentationBytes(presentation) ?: defaultSlideSize()
        }
        return readSldSzEarly(zip, names) ?: defaultSlideSize()
    }

    /**
     * Reads only until `p:sldSz` closes, or 512 KB, whichever comes first.
     * Slide ids and default text styles after that tag are not loaded.
     */
    private fun readSldSzEarly(zip: ZipFile, names: ZipNameIndex): AppliedSlideSize? {
        val raw = names.lookup("ppt/presentation.xml") ?: return null
        val entry = zip.getEntry(raw) ?: return null
        val cap = 512 * 1024
        val window = ByteArrayOutputStream()
        zip.getInputStream(entry).use { input ->
            val buf = ByteArray(4096)
            var total = 0
            while (total < cap) {
                val n = input.read(buf, 0, minOf(buf.size, cap - total))
                if (n < 0) break
                window.write(buf, 0, n)
                total += n
                val tag = sldSzTag(window.toByteArray())
                if (tag != null) return sizeFromTag(tag)
            }
        }
        return sldSzTag(window.toByteArray())?.let { sizeFromTag(it) }
    }

    private fun sizeFromPresentationBytes(bytes: ByteArray): AppliedSlideSize? {
        val tag = sldSzTag(bytes) ?: return null
        return sizeFromTag(tag)
    }

    private fun sldSzTag(bytes: ByteArray): String? {
        var from = 0
        while (from < bytes.size) {
            val at = indexOfAscii(bytes, "sldSz", from)
            if (at < 0) return null
            var start = at
            var back = 0
            while (start > 0 && back < 24 && bytes[start - 1].toInt().and(0xFF) != '<'.code) {
                start--
                back++
            }
            val opened = start > 0 && bytes[start - 1].toInt().and(0xFF) == '<'.code
            if (!opened) {
                from = at + 5
                continue
            }
            start--
            var end = at
            while (end < bytes.size && bytes[end].toInt().and(0xFF) != '>'.code) end++
            if (end >= bytes.size) return null
            return bytes.copyOfRange(start, end + 1).toString(Charsets.UTF_8)
        }
        return null
    }

    private fun indexOfAscii(bytes: ByteArray, needle: String, from: Int = 0): Int {
        val n = needle.toByteArray(Charsets.US_ASCII)
        if (n.isEmpty() || from < 0 || bytes.size < from + n.size) return -1
        var i = from
        val last = bytes.size - n.size
        while (i <= last) {
            var ok = true
            for (j in n.indices) {
                if (bytes[i + j] != n[j]) {
                    ok = false
                    break
                }
            }
            if (ok) return i
            i++
        }
        return -1
    }

    private fun sizeFromTag(tag: String): AppliedSlideSize {
        val fallback = defaultSlideSize()
        val cx = attrLong(tag, "cx")?.takeIf { it > 0L } ?: fallback.cx
        val cy = attrLong(tag, "cy")?.takeIf { it > 0L } ?: fallback.cy
        return AppliedSlideSize(cx, cy, slideSizeType(cx, cy, attrString(tag, "type")))
    }

    private fun attrString(tag: String, name: String): String? {
        val match = Regex(
            """(?:^|[\s/])$name\s*=\s*(?:"([^"]*)"|'([^']*)')""",
        ).find(tag) ?: return null
        val quoted = match.groupValues[1].ifEmpty { match.groupValues[2] }
        return quoted.trim().ifEmpty { null }
    }

    private fun attrLong(tag: String, name: String): Long? {
        return attrString(tag, name)?.toLongOrNull()
    }

    /** OOXML omits type on many 16:9 decks. pptxjs then logs `undefined`. */
    private fun slideSizeType(cx: Long, cy: Long, declared: String?): String {
        val clean = declared?.trim()?.takeIf { it.matches(Regex("""[A-Za-z0-9]+""")) }
        if (clean != null) return clean
        if (cy <= 0L) return "screen16x9"
        val ratio = cx.toDouble() / cy.toDouble()
        val wide = 16.0 / 9.0
        val standard = 4.0 / 3.0
        return if (kotlin.math.abs(ratio - wide) <= kotlin.math.abs(ratio - standard)) {
            "screen16x9"
        } else {
            "screen4x3"
        }
    }

    private fun presentationWithSize(existing: ByteArray?, size: AppliedSlideSize): ByteArray {
        val tag = "<p:sldSz cx=\"${size.cx}\" cy=\"${size.cy}\" type=\"${size.type}\"/>"
        if (existing == null || existing.isEmpty()) return presentationStub(size)
        val text = existing.toString(Charsets.UTF_8)
        if (sldSzElement.containsMatchIn(text)) {
            return sldSzElement.replace(text, tag).toByteArray(Charsets.UTF_8)
        }
        val root = Regex(
            """<(?:[A-Za-z_][\w.-]*:)?presentation\b[^>]*>""",
            RegexOption.IGNORE_CASE,
        ).find(text) ?: return presentationStub(size)
        val at = root.range.last + 1
        return (text.substring(0, at) + tag + text.substring(at)).toByteArray(Charsets.UTF_8)
    }

    private fun presentationStub(size: AppliedSlideSize = defaultSlideSize()): ByteArray {
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
            <p:sldSz cx="${size.cx}" cy="${size.cy}" type="${size.type}"/>
            <p:defaultTextStyle/>
            </p:presentation>
        """.trimIndent().toByteArray(Charsets.UTF_8)
    }

    private fun isVideoPart(name: String): Boolean {
        val ext = name.substringAfterLast('.', "")
            .substringBefore('?')
            .lowercase()
        return ext == "mp4" || ext == "m4v" || ext == "mov" || ext == "avi" ||
            ext == "wmv" || ext == "mpg" || ext == "mpeg" || ext == "webm" ||
            ext == "ogv" || ext == "3gp" || ext == "mkv"
    }

    private fun appStub(): ByteArray {
        return """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">
            <AppVersion>16.0000</AppVersion>
            </Properties>
        """.trimIndent().toByteArray(Charsets.UTF_8)
    }

    private fun clearMediaDir(dir: File) {
        if (!dir.exists()) {
            dir.mkdirs()
            return
        }
        dir.listFiles()?.forEach { child ->
            if (child.isFile) child.delete()
        }
    }

    private fun isInsideCache(activity: Activity, file: File): Boolean {
        return try {
            val cache = activity.cacheDir.canonicalFile
            val target = file.canonicalFile
            val prefix = cache.path + File.separator
            target.path.startsWith(prefix)
        } catch (_: Exception) {
            false
        }
    }

    private class ZipNameIndex(zip: ZipFile) {
        val actual = HashMap<String, String>()
        val originals = ArrayList<String>()

        init {
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val raw = entries.nextElement().name.replace('\\', '/')
                if (raw.endsWith("/")) continue
                val key = raw.removePrefix("/")
                if (actual.containsKey(key)) continue
                actual[key] = raw
                actual[key.lowercase()] = raw
                originals.add(key)
            }
        }

        fun lookup(logical: String): String? {
            val key = logical.replace('\\', '/').removePrefix("/")
            return actual[key] ?: actual[key.lowercase()]
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

    /**
     * First paragraph window, for callers that still expect one document map.
     * The viewer itself asks for each window and does not use this path.
     */
    private fun wordWindowDocument(
        file: File,
        filePath: String,
        format: String,
    ): Map<String, Any> {
        val page = WordWindowReader(TAG).read(file, format, 0)
        val rawBlocks = page["blocks"] as? List<*> ?: emptyList<Any>()
        val texts = mutableListOf<String>()
        val documentBlocks = mutableListOf<Map<String, Any>>()
        for (item in rawBlocks) {
            val block = item as? Map<*, *> ?: continue
            if (block["skipped"] == true) continue
            val text = block["text"]?.toString()?.trim().orEmpty()
            if (text.isEmpty()) continue
            texts.add(text)
            documentBlocks.add(
                mapOf(
                    "type" to "paragraph",
                    "inlines" to listOf(
                        mapOf(
                            "type" to "text",
                            "text" to text,
                            "style" to emptyMap<String, Any>(),
                        ),
                    ),
                ),
            )
        }
        if (page["failed"] == true && texts.isEmpty()) {
            throw IllegalStateException("This file could not be opened.")
        }
        val plain = texts.joinToString("\n")
        val wordCount = plain.split(Regex("\\s+")).count { it.isNotBlank() }
        return mapOf(
            "textContent" to plain,
            "plainTextContent" to plain,
            "documentBlocks" to documentBlocks,
            "parseWarnings" to listOf(
                "Showing the first section of this document.",
            ),
            "fidelityLevel" to "partial",
            "wordCount" to wordCount,
            "lineCount" to texts.size.coerceAtLeast(1),
            "format" to format,
            "filePath" to filePath,
        )
    }

    private fun parseDOCX(filePath: String): Map<String, Any> {
        logStep("parseDOCX:start")
        val file = File(filePath)
        val xmlSize = zipEntrySize(file, "word/document.xml")
        if (xmlSize > maxDocxXmlBytes || file.length() > maxDocxVisualBytes) {
            logStep("parseDOCX:stream window xml=$xmlSize file=${file.length()}")
            return wordWindowDocument(file, filePath, "DOCX")
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
        if (file.length() > maxDocBytes) {
            logStep("parseDOC:stream window, skip HWPFDocument")
            return wordWindowDocument(file, filePath, "DOC")
        }
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

    private fun readXlsxWindow(
        file: File,
        sheetIndex: Int,
        startRow: Int,
        rowCount: Int,
        startCol: Int,
        colCount: Int,
    ): Map<String, Any> {
        ZipFile(file, StandardCharsets.UTF_8).use { zip ->
            val workbook = workbookZipEntry(zip)
                ?: throw IllegalStateException("This file could not be opened.")
            val names = ArrayList<String>()
            val paths = ArrayList<String>()
            readWorkbookSheets(zip, workbook, names, paths)
            if (sheetIndex !in paths.indices) {
                return sheetWindowResult(
                    names, sheetIndex, startRow, startCol,
                    emptyList(), false, false, false,
                )
            }
            return try {
                val sheetStarted = System.currentTimeMillis()
                val scan = scanXlsxSheet(
                    zip, paths[sheetIndex], startRow, rowCount, startCol, colCount,
                )
                val sheetMs = System.currentTimeMillis() - sheetStarted
                val strings = try {
                    readNeededSharedStrings(zip, scan.needed)
                } catch (t: Throwable) {
                    Log.w(TAG, "xlsx shared strings skipped: ${t.message}")
                    if (t is Error && t !is OutOfMemoryError) throw t
                    emptyMap()
                }
                val sstMs = System.currentTimeMillis() - sheetStarted - sheetMs
                val built = buildWindowGrid(
                    scan.originRow, rowCount, startCol, colCount, scan.maxRow, scan.maxCol,
                ) { row, col ->
                    val key = cellKey(row, col)
                    scan.inline[key] ?: scan.sstAt[key]?.let { strings[it] }.orEmpty()
                }
                logStep(
                    "xlsx window origin=${scan.originRow} " +
                        "grid=${built.first.size}x${built.first.firstOrNull()?.size ?: 0} " +
                        "strings=${scan.needed.size} sheet=${sheetMs}ms sst=${sstMs}ms",
                )
                sheetWindowResult(
                    names, sheetIndex, scan.originRow, startCol,
                    built.first,
                    scan.hasMoreRows,
                    scan.hasMoreCols || built.third,
                    false,
                )
            } catch (t: Throwable) {
                Log.e(TAG, "xlsx sheet window failed", t)
                if (t is Error && t !is OutOfMemoryError) throw t
                sheetWindowResult(
                    names, sheetIndex, startRow, startCol,
                    emptyList(), false, false, true,
                )
            }
        }
    }

    private class XlsxScan {
        var originRow = 0
        var maxRow = -1
        var maxCol = -1
        var hasMoreRows = false
        var hasMoreCols = false
        var anchored = false
        var dimStartRow = -1
        var dimEndRow = -1
        var dimEndCol = -1
        val inline = HashMap<Long, String>()
        val sstAt = HashMap<Long, Int>()
        val needed = HashSet<Int>()
    }

    private fun scanXlsxSheet(
        zip: ZipFile,
        path: String,
        startRow: Int,
        rowCount: Int,
        startCol: Int,
        colCount: Int,
    ): XlsxScan {
        val scan = XlsxScan()
        scan.originRow = startRow
        if (path.isEmpty()) return scan
        val entry = zipEntryExact(zip, path) ?: return scan
        zip.getInputStream(entry).use { input ->
            val parser = newPullParser(input)
            var event = parser.eventType
            var inSheetData = false
            var inRow = false
            var inCell = false
            var inInline = false
            var inFormula = false
            var inValue = false
            var inText = false
            var skipRow = false
            var stop = false
            var phonetic = 0
            var rowNumber = -1
            var colNumber = -1
            var nextCol = 0
            var cellType = ""
            val text = StringBuilder()
            while (event != XmlPullParser.END_DOCUMENT && !stop) {
                val name = if (
                    event == XmlPullParser.START_TAG || event == XmlPullParser.END_TAG
                ) {
                    xmlLocalName(parser)
                } else {
                    ""
                }
                when (event) {
                    XmlPullParser.START_TAG -> when (name) {
                        "dimension" -> if (!inSheetData) {
                            xmlAttr(parser, "ref")?.let { applyXlsxDimension(scan, it) }
                        }
                        "sheetData" -> {
                            inSheetData = true
                            if (scan.dimStartRow >= 0 &&
                                scan.originRow + rowCount <= scan.dimStartRow
                            ) {
                                scan.originRow = scan.dimStartRow
                            }
                        }
                        "row" -> if (inSheetData) {
                            val declared = xmlAttr(parser, "r")?.toIntOrNull()
                            rowNumber = if (declared != null && declared > 0) {
                                declared - 1
                            } else {
                                rowNumber + 1
                            }
                            nextCol = 0
                            if (!scan.anchored &&
                                scan.inline.isEmpty() &&
                                scan.sstAt.isEmpty() &&
                                rowNumber >= scan.originRow + rowCount
                            ) {
                                scan.originRow = rowNumber
                            }
                            when {
                                rowNumber >= scan.originRow + rowCount -> {
                                    scan.hasMoreRows = true
                                    stop = true
                                }
                                rowNumber < scan.originRow -> {
                                    inRow = true
                                    skipRow = true
                                }
                                else -> {
                                    inRow = true
                                    skipRow = false
                                    scan.anchored = true
                                    if (rowNumber > scan.maxRow) scan.maxRow = rowNumber
                                }
                            }
                        }
                        "c" -> if (inRow && !skipRow) {
                            inCell = true
                            cellType = xmlAttr(parser, "t").orEmpty()
                            text.setLength(0)
                            val parsed = xmlAttr(parser, "r")?.let { parseA1(it) }
                            colNumber = parsed?.first ?: nextCol
                            if (parsed != null) rowNumber = parsed.second
                            nextCol = colNumber + 1
                            if (colNumber >= startCol + colCount) {
                                scan.hasMoreCols = true
                            } else if (colNumber >= startCol && colNumber > scan.maxCol) {
                                scan.maxCol = colNumber
                            }
                        }
                        "is" -> if (inCell) inInline = true
                        "f" -> if (inCell) inFormula = true
                        "v" -> if (inCell && !inFormula) {
                            inValue = true
                            text.setLength(0)
                        }
                        "rPh", "phoneticPr" -> phonetic++
                        "t" -> if (inInline && phonetic == 0) inText = true
                    }
                    XmlPullParser.TEXT -> if (phonetic == 0 && (inValue || inText)) {
                        appendCapped(text, parser.text)
                    }
                    XmlPullParser.END_TAG -> when (name) {
                        "t" -> inText = false
                        "v" -> inValue = false
                        "f" -> inFormula = false
                        "is" -> inInline = false
                        "rPh", "phoneticPr" -> if (phonetic > 0) phonetic--
                        "c" -> {
                            if (inCell) {
                                commitXlsxCell(
                                    scan, rowNumber, colNumber, cellType, text.toString(),
                                    scan.originRow, rowCount, startCol, colCount,
                                )
                            }
                            inCell = false
                            inValue = false
                            inText = false
                            text.setLength(0)
                        }
                        "row" -> {
                            inRow = false
                            skipRow = false
                        }
                        "sheetData" -> inSheetData = false
                    }
                }
                if (stop) break
                event = parser.next()
            }
        }
        if (scan.dimEndRow >= scan.originRow + rowCount) scan.hasMoreRows = true
        if (scan.dimEndCol >= startCol + colCount) scan.hasMoreCols = true
        if (scan.dimEndCol >= startCol) {
            val capped = minOf(scan.dimEndCol, startCol + colCount - 1)
            if (capped > scan.maxCol) scan.maxCol = capped
        }
        return scan
    }

    private fun applyXlsxDimension(scan: XlsxScan, ref: String) {
        val parts = ref.split(':')
        val start = parseA1(parts[0].trim()) ?: return
        val end = if (parts.size > 1) parseA1(parts[1].trim()) ?: start else start
        scan.dimStartRow = minOf(start.second, end.second)
        scan.dimEndRow = maxOf(start.second, end.second)
        scan.dimEndCol = maxOf(start.first, end.first)
    }

    private fun commitXlsxCell(
        scan: XlsxScan,
        row: Int,
        col: Int,
        cellType: String,
        raw: String,
        startRow: Int,
        rowCount: Int,
        startCol: Int,
        colCount: Int,
    ) {
        if (row < startRow || row >= startRow + rowCount) return
        if (col < startCol || col >= startCol + colCount) return
        val key = cellKey(row, col)
        if (cellType == "s") {
            val index = raw.trim().toIntOrNull() ?: return
            if (index < 0) return
            scan.sstAt[key] = index
            scan.needed.add(index)
            return
        }
        val shown = if (cellType == "b") {
            when (raw.trim()) {
                "1" -> "TRUE"
                "0" -> "FALSE"
                else -> raw.trim()
            }
        } else {
            raw.trim()
        }
        if (shown.isNotEmpty()) scan.inline[key] = clipWindowCell(shown)
    }

    private fun readNeededSharedStrings(zip: ZipFile, needed: Set<Int>): Map<Int, String> {
        if (needed.isEmpty()) return emptyMap()
        val entry = findZipEntry(zip) { name ->
            !name.contains("/_rels/") &&
                (name == "xl/sharedStrings.xml" || name.endsWith("/sharedStrings.xml"))
        } ?: return emptyMap()
        val kept = HashMap<Int, String>(needed.size)
        zip.getInputStream(entry).use { input ->
            SstByteReader(input, needed, kept, windowCellChars).read()
        }
        if (kept.size < needed.size) {
            Log.w(TAG, "xlsx sst kept ${kept.size} of ${needed.size}")
        }
        return kept
    }

    /** Shared-string tag. Nested classes are illegal inside an inner class. */
    private class SstTag(val local: String, val end: Boolean, val selfClosing: Boolean)

    /**
     * Counts shared-string items and keeps only [needed]. Unneeded items are
     * skipped by searching for the end tag, so a million-item table is not
     * turned into a parser tree or retained.
     */
    private inner class SstByteReader(
        private val input: InputStream,
        private val needed: Set<Int>,
        private val kept: MutableMap<Int, String>,
        private val maxChars: Int,
    ) {
        private val buf = ByteArray(1024 * 1024)
        private var pos = 0
        private var limit = 0
        private var eof = false

        fun read() {
            var index = -1
            while (kept.size < needed.size) {
                if (!skipUntil('<'.code)) return
                val kind = peekPlainSi()
                if (kind == 0) {
                    val tag = readTag() ?: continue
                    if (tag.local != "si" || tag.end) continue
                    index++
                    if (tag.selfClosing) {
                        if (index in needed) kept[index] = ""
                        continue
                    }
                    if (index !in needed) {
                        if (!skipSiEnd()) return
                        continue
                    }
                    kept[index] = readSiText()
                    continue
                }
                index++
                if (kind == 2) {
                    if (index in needed) kept[index] = ""
                    continue
                }
                if (index !in needed) {
                    if (!skipSiEnd()) return
                } else {
                    kept[index] = readSiText()
                }
            }
        }

        /** 1 = `<si>`, 2 = `<si/>`, 0 = some other tag. Advances only for 1 and 2. */
        private fun peekPlainSi(): Int {
            if (limit - pos < 4 && !pull()) return 0
            if (limit - pos < 4) return 0
            if (buf[pos] != '<'.code.toByte() ||
                buf[pos + 1] != 's'.code.toByte() ||
                buf[pos + 2] != 'i'.code.toByte()
            ) {
                return 0
            }
            if (buf[pos + 3] == '>'.code.toByte()) {
                pos += 4
                return 1
            }
            if (buf[pos + 3] == '/'.code.toByte()) {
                if (limit - pos < 5 && !pull()) return 0
                if (limit - pos >= 5 && buf[pos + 4] == '>'.code.toByte()) {
                    pos += 5
                    return 2
                }
            }
            return 0
        }

        private fun readSiText(): String {
            val text = StringBuilder()
            var phonetic = 0
            while (true) {
                if (!skipUntil('<'.code)) break
                val tag = readTag() ?: continue
                if (tag.local == "si" && tag.end && phonetic == 0) break
                if (tag.local == "rPh" || tag.local == "phoneticPr") {
                    if (tag.end) {
                        if (phonetic > 0) phonetic--
                    } else if (!tag.selfClosing) {
                        phonetic++
                    }
                    continue
                }
                if (tag.local == "t" && !tag.end && !tag.selfClosing && phonetic == 0) {
                    appendDecoded(text, readUntil('<'.code))
                }
            }
            return text.toString()
        }

        private fun skipSiEnd(): Boolean {
            val bytes = buf
            val lt = '<'.code.toByte()
            val slash = '/'.code.toByte()
            val sByte = 's'.code.toByte()
            val iByte = 'i'.code.toByte()
            val gt = '>'.code.toByte()
            while (true) {
                var p = pos
                val lim = limit
                while (p < lim) {
                    if (bytes[p] == lt) {
                        if (p + 5 > lim && !eof) {
                            pos = p
                            if (!pull()) return false
                            break
                        }
                        if (p + 5 <= lim &&
                            bytes[p + 1] == slash &&
                            bytes[p + 2] == sByte &&
                            bytes[p + 3] == iByte &&
                            bytes[p + 4] == gt
                        ) {
                            pos = p + 5
                            return true
                        }
                    }
                    p++
                }
                if (p >= lim) {
                    pos = lim
                    if (!pull()) return false
                }
            }
        }

        private fun skipUntil(target: Int): Boolean {
            while (true) {
                var p = pos
                val lim = limit
                while (p < lim) {
                    if ((buf[p].toInt() and 0xFF) == target) {
                        pos = p
                        return true
                    }
                    p++
                }
                pos = lim
                if (!pull()) return false
            }
        }

        private fun readUntil(target: Int): ByteArray {
            val out = ByteArrayOutputStream()
            var capped = false
            while (true) {
                if (pos >= limit && !pull()) break
                val c = buf[pos].toInt() and 0xFF
                if (c == target) break
                pos++
                if (!capped) {
                    out.write(c)
                    if (out.size() >= maxChars * 4) capped = true
                }
            }
            return out.toByteArray()
        }

        private fun appendDecoded(into: StringBuilder, raw: ByteArray) {
            if (raw.isEmpty() || into.length >= maxChars) return
            var text = String(raw, StandardCharsets.UTF_8)
            if (text.indexOf('&') >= 0) text = decodeXmlEntities(text)
            val room = maxChars - into.length
            if (text.length <= room) into.append(text) else into.append(text, 0, room)
        }

        private fun readTag(): SstTag? {
            if (pos >= limit && !pull()) return null
            if ((buf[pos].toInt() and 0xFF) != '<'.code) return null
            pos++
            if (pos >= limit && !pull()) return null
            val mark = buf[pos].toInt() and 0xFF
            if (mark == '?'.code || mark == '!'.code) {
                if (mark == '!'.code && lookingAt("!--")) {
                    skipUntilSequence("-->")
                } else {
                    skipUntil('>'.code)
                    if (pos < limit && (buf[pos].toInt() and 0xFF) == '>'.code) pos++
                }
                return null
            }
            val end = mark == '/'.code
            if (end) pos++
            val name = StringBuilder()
            while (true) {
                if (pos >= limit && !pull()) break
                val c = buf[pos].toInt() and 0xFF
                if (c == '>'.code || c == '/'.code || c <= 32) break
                name.append(c.toChar())
                pos++
                if (name.length > 80) break
            }
            var selfClosing = false
            while (true) {
                if (pos >= limit && !pull()) break
                val c = buf[pos].toInt() and 0xFF
                if (c == '>'.code) {
                    pos++
                    break
                }
                if (c == '/'.code) selfClosing = true
                pos++
            }
            val raw = name.toString()
            val colon = raw.lastIndexOf(':')
            val local = if (colon >= 0) raw.substring(colon + 1) else raw
            return SstTag(local, end, selfClosing)
        }

        private fun lookingAt(token: String): Boolean {
            if (limit - pos < token.length && !pull()) return false
            if (limit - pos < token.length) return false
            for (i in token.indices) {
                if ((buf[pos + i].toInt() and 0xFF) != token[i].code) return false
            }
            return true
        }

        private fun skipUntilSequence(token: String) {
            val first = token[0].code
            while (skipUntil(first)) {
                if (lookingAt(token)) {
                    pos += token.length
                    return
                }
                pos++
            }
        }

        private fun pull(): Boolean {
            if (pos > 0 && pos < limit) {
                val keep = limit - pos
                buf.copyInto(buf, 0, pos, limit)
                pos = 0
                limit = keep
            } else if (pos >= limit) {
                pos = 0
                limit = 0
            }
            if (eof || limit >= buf.size) return limit > pos
            val n = input.read(buf, limit, buf.size - limit)
            if (n <= 0) eof = true else limit += n
            return limit > pos
        }
    }

    private fun decodeXmlEntities(raw: String): String {
        val sb = StringBuilder(raw.length)
        var i = 0
        while (i < raw.length) {
            if (raw[i] != '&') {
                sb.append(raw[i])
                i++
                continue
            }
            val semi = raw.indexOf(';', i + 1)
            if (semi < 0 || semi - i > 12) {
                sb.append('&')
                i++
                continue
            }
            val body = raw.substring(i + 1, semi)
            val ch = when (body) {
                "amp" -> '&'
                "lt" -> '<'
                "gt" -> '>'
                "quot" -> '"'
                "apos" -> '\''
                else -> {
                    val code = when {
                        body.startsWith("#x") || body.startsWith("#X") ->
                            body.substring(2).toIntOrNull(16)
                        body.startsWith("#") -> body.substring(1).toIntOrNull()
                        else -> null
                    }
                    if (code != null && code in 0..0xFFFF) code.toChar() else null
                }
            }
            if (ch == null) {
                sb.append('&')
                i++
            } else {
                sb.append(ch)
                i = semi + 1
            }
        }
        return sb.toString()
    }

    private fun readWorkbookSheets(
        zip: ZipFile,
        workbook: ZipEntry,
        names: MutableList<String>,
        paths: MutableList<String>,
    ) {
        val bookPath = workbook.name.replace('\\', '/')
        val rels = HashMap<String, String>()
        val relsEntry = zip.getEntry(workbookRelsPath(bookPath))
        if (relsEntry != null) {
            zip.getInputStream(relsEntry).use { input ->
                val parser = newPullParser(input)
                var event = parser.eventType
                while (event != XmlPullParser.END_DOCUMENT) {
                    if (event == XmlPullParser.START_TAG && xmlLocalName(parser) == "Relationship") {
                        val id = xmlAttr(parser, "Id")
                        val target = xmlAttr(parser, "Target")
                        val external = xmlAttr(parser, "TargetMode")
                            ?.equals("External", ignoreCase = true) == true
                        if (!id.isNullOrEmpty() && !target.isNullOrEmpty() && !external) {
                            rels[id] = resolveZipTarget(bookPath, target)
                        }
                    }
                    event = parser.next()
                }
            }
        }
        zip.getInputStream(workbook).use { input ->
            val parser = newPullParser(input)
            var event = parser.eventType
            while (event != XmlPullParser.END_DOCUMENT) {
                if (event == XmlPullParser.START_TAG && xmlLocalName(parser) == "sheet") {
                    val rawName = xmlAttr(parser, "name")?.trim().orEmpty()
                    val name = rawName.take(128).ifBlank { "Sheet ${names.size + 1}" }
                    val id = xmlAttr(parser, "id")
                    names.add(name)
                    paths.add(if (id.isNullOrEmpty()) "" else rels[id].orEmpty())
                }
                event = parser.next()
            }
        }
    }

    private fun readXlsWindow(
        file: File,
        sheetIndex: Int,
        startRow: Int,
        rowCount: Int,
        startCol: Int,
        colCount: Int,
    ): Map<String, Any> {
        val fs = POIFSFileSystem(file, true)
        try {
            val accum = XlsWindowAccum(sheetIndex, startRow, rowCount, startCol, colCount)
            walkXls(
                fs,
                onSst = { input ->
                    readSparseSst(input, emptySet())
                    false
                },
                onRecord = { record -> consumeXlsRecord(record, accum) },
            )
            val strings = if (accum.needed.isEmpty()) {
                emptyMap()
            } else {
                try {
                    loadSparseSst(fs, accum.needed)
                } catch (t: Throwable) {
                    Log.w(TAG, "xls sparse sst failed: ${t.message}")
                    if (t is Error && t !is OutOfMemoryError) throw t
                    emptyMap()
                }
            }
            val built = buildWindowGrid(
                startRow, rowCount, startCol, colCount, accum.maxRow, accum.maxCol,
            ) { row, col ->
                val key = cellKey(row, col)
                accum.inline[key] ?: accum.sstAt[key]?.let { strings[it] }.orEmpty()
            }
            return sheetWindowResult(
                accum.names, sheetIndex, startRow, startCol,
                built.first, built.second, built.third, false,
            )
        } finally {
            try {
                fs.close()
            } catch (_: Exception) {
            }
        }
    }

    private class XlsWindowAccum(
        val target: Int,
        val startRow: Int,
        val rowCount: Int,
        val startCol: Int,
        val colCount: Int,
    ) {
        val names = ArrayList<String>()
        var sheetOrdinal = -1
        var maxRow = -1
        var maxCol = -1
        var outputNextString = false
        var pendingRow = -1
        var pendingCol = -1
        val needed = HashSet<Int>()
        val inline = HashMap<Long, String>()
        val sstAt = HashMap<Long, Int>()
        val onTarget: Boolean get() = sheetOrdinal == target
    }

    private fun consumeXlsRecord(
        record: org.apache.poi.hssf.record.Record,
        accum: XlsWindowAccum,
    ) {
        when (record.sid.toInt()) {
            BoundSheetRecord.sid.toInt() -> {
                val raw = (record as BoundSheetRecord).sheetname?.trim().orEmpty()
                accum.names.add(raw.take(128).ifBlank { "Sheet ${accum.names.size + 1}" })
            }
            BOFRecord.sid.toInt() -> {
                val type = (record as BOFRecord).type.toInt()
                if (type == BOFRecord.TYPE_WORKSHEET.toInt() ||
                    type == BOFRecord.TYPE_CHART.toInt() ||
                    type == BOFRecord.TYPE_EXCEL_4_MACRO.toInt()
                ) {
                    accum.outputNextString = false
                    accum.sheetOrdinal += 1
                }
            }
            BlankRecord.sid.toInt() -> {
                val cell = record as BlankRecord
                noteXlsCell(accum, cell.row, cell.column.toInt(), null, null)
            }
            MulBlankRecord.sid.toInt() -> {
                val cell = record as MulBlankRecord
                var col = cell.firstColumn.toInt()
                val last = cell.lastColumn.toInt()
                while (col <= last) {
                    noteXlsCell(accum, cell.row, col, null, null)
                    col++
                }
            }
            BoolErrRecord.sid.toInt() -> {
                val cell = record as BoolErrRecord
                val text = if (cell.isBoolean) {
                    if (cell.booleanValue) "TRUE" else "FALSE"
                } else {
                    "ERROR"
                }
                noteXlsCell(accum, cell.row, cell.column.toInt(), text, null)
            }
            FormulaRecord.sid.toInt() -> {
                val cell = record as FormulaRecord
                if (java.lang.Double.isNaN(cell.value)) {
                    accum.outputNextString = true
                    accum.pendingRow = cell.row
                    accum.pendingCol = cell.column.toInt()
                } else {
                    accum.outputNextString = false
                    noteXlsCell(
                        accum, cell.row, cell.column.toInt(), plainNumber(cell.value), null,
                    )
                }
            }
            StringRecord.sid.toInt() -> {
                if (accum.outputNextString) {
                    noteXlsCell(
                        accum,
                        accum.pendingRow,
                        accum.pendingCol,
                        (record as StringRecord).string,
                        null,
                    )
                    accum.outputNextString = false
                }
            }
            LabelRecord.sid.toInt() -> {
                val cell = record as LabelRecord
                noteXlsCell(accum, cell.row, cell.column.toInt(), cell.value, null)
            }
            LabelSSTRecord.sid.toInt() -> {
                val cell = record as LabelSSTRecord
                noteXlsCell(accum, cell.row, cell.column.toInt(), null, cell.sstIndex)
            }
            NumberRecord.sid.toInt() -> {
                val cell = record as NumberRecord
                noteXlsCell(
                    accum, cell.row, cell.column.toInt(), plainNumber(cell.value), null,
                )
            }
            RKRecord.sid.toInt() -> {
                val cell = record as RKRecord
                noteXlsCell(
                    accum, cell.row, cell.column.toInt(), plainNumber(cell.rkNumber), null,
                )
            }
            MulRKRecord.sid.toInt() -> {
                val cell = record as MulRKRecord
                var col = cell.firstColumn.toInt()
                val last = cell.lastColumn.toInt()
                var offset = 0
                while (col <= last && offset < 512) {
                    noteXlsCell(
                        accum, cell.row, col, plainNumber(cell.getRKNumberAt(offset)), null,
                    )
                    col++
                    offset++
                }
            }
        }
    }

    private fun noteXlsCell(
        accum: XlsWindowAccum,
        row: Int,
        col: Int,
        text: String?,
        sst: Int?,
    ) {
        if (!accum.onTarget || row < 0 || col < 0) return
        if (row > accum.maxRow) accum.maxRow = row
        if (col > accum.maxCol) accum.maxCol = col
        if (row < accum.startRow || row >= accum.startRow + accum.rowCount) return
        if (col < accum.startCol || col >= accum.startCol + accum.colCount) return
        val key = cellKey(row, col)
        if (sst != null && sst >= 0) {
            accum.sstAt[key] = sst
            accum.needed.add(sst)
            return
        }
        if (!text.isNullOrEmpty()) accum.inline[key] = clipWindowCell(text)
    }

    /**
     * @return true when the walk should stop after the shared-string table.
     */
    private fun walkXls(
        fs: POIFSFileSystem,
        onSst: (RecordInputStream) -> Boolean,
        onRecord: (org.apache.poi.hssf.record.Record) -> Unit,
    ) {
        val root = fs.root
        val entryName = InternalWorkbook.WORKBOOK_DIR_ENTRY_NAMES
            .firstOrNull { root.hasEntry(it) }
            ?: throw IllegalStateException("This .xls file has no workbook stream.")
        val scratch = ByteArray(8192)
        root.createDocumentInputStream(entryName).use { document ->
            val input = RecordInputStream(document)
            while (input.hasNextRecord()) {
                try {
                    input.nextRecord()
                } catch (t: Throwable) {
                    if (isOversizedRecord(t)) {
                        Log.w(TAG, "xls record header skipped: ${t.message}")
                        break
                    }
                    throw t
                }
                try {
                    if (input.sid.toInt() == SSTRecord.sid.toInt()) {
                        try {
                            if (onSst(input)) break
                        } catch (t: Throwable) {
                            Log.w(TAG, "xls sst skipped: ${t.message}")
                            if (t is Error && t !is OutOfMemoryError) throw t
                            break
                        }
                        continue
                    }
                    if (input.remaining() > maxWindowRecordBytes) {
                        Log.w(
                            TAG,
                            "xls record sid=${input.sid} bytes=${input.remaining()} skipped",
                        )
                        skipExact(input, input.remaining(), scratch)
                        continue
                    }
                    val created = RecordFactory.createRecord(input) ?: continue
                    for (record in created) {
                        if (record != null) onRecord(record)
                    }
                } catch (t: Throwable) {
                    Log.w(TAG, "xls record skipped: ${t.javaClass.simpleName}: ${t.message}")
                    try {
                        if (input.remaining() > 0) skipExact(input, input.remaining(), scratch)
                    } catch (_: Throwable) {
                    }
                    if (t is OutOfMemoryError || isOversizedRecord(t)) break
                    if (t is Error) throw t
                }
            }
        }
    }

    private fun loadSparseSst(fs: POIFSFileSystem, needed: Set<Int>): Map<Int, String> {
        var found: Map<Int, String> = emptyMap()
        walkXls(
            fs,
            onSst = { input ->
                found = readSparseSst(input, needed)
                true
            },
            onRecord = {},
        )
        return found
    }

    private fun readSparseSst(input: RecordInputStream, needed: Set<Int>): Map<Int, String> {
        val kept = HashMap<Int, String>(minOf(needed.size.coerceAtLeast(1), 64))
        val scratch = ByteArray(8192)
        try {
            val total = input.readInt()
            val unique = input.readInt()
            if (needed.isNotEmpty()) {
                logStep("xls window sst total=$total unique=$unique need=${needed.size}")
            }
            if (total < 0 || unique < 0) return kept
            var index = 0
            while (index < unique) {
                val want = index in needed
                val text = readSstString(input, if (want) windowCellChars else 0, scratch)
                if (want) kept[index] = text
                index++
            }
        } catch (t: Throwable) {
            Log.w(TAG, "xls sst stopped: ${t.javaClass.simpleName}: ${t.message}")
            if (t is Error && t !is OutOfMemoryError) throw t
        } finally {
            try {
                drainRecord(input, scratch)
            } catch (_: Throwable) {
            }
        }
        return kept
    }

    private fun sheetWindowResult(
        names: List<String>,
        sheetIndex: Int,
        startRow: Int,
        startCol: Int,
        rows: List<List<String>>,
        hasMoreRows: Boolean,
        hasMoreCols: Boolean,
        failed: Boolean,
    ): Map<String, Any> {
        return mapOf(
            "sheetNames" to names.toList(),
            "sheetName" to (names.getOrNull(sheetIndex) ?: ""),
            "sheetIndex" to sheetIndex,
            "sheetCount" to names.size,
            "startRow" to startRow,
            "startCol" to startCol,
            "rowCount" to rows.size,
            "colCount" to (rows.firstOrNull()?.size ?: 0),
            "rows" to rows,
            "hasMoreRows" to hasMoreRows,
            "hasMoreCols" to hasMoreCols,
            "failed" to failed,
        )
    }

    private fun buildWindowGrid(
        startRow: Int,
        rowCount: Int,
        startCol: Int,
        colCount: Int,
        maxRow: Int,
        maxCol: Int,
        fill: (Int, Int) -> String,
    ): Triple<List<List<String>>, Boolean, Boolean> {
        if (maxRow < startRow || maxCol < startCol) {
            return Triple(emptyList(), false, false)
        }
        val endRow = minOf(startRow + rowCount - 1, maxRow)
        val endCol = minOf(startCol + colCount - 1, maxCol)
        val actualRows = endRow - startRow + 1
        val actualCols = endCol - startCol + 1
        if (actualRows <= 0 || actualCols <= 0) {
            return Triple(emptyList(), false, false)
        }
        val rows = ArrayList<List<String>>(actualRows)
        for (localRow in 0 until actualRows) {
            val absRow = startRow + localRow
            val line = ArrayList<String>(actualCols)
            for (localCol in 0 until actualCols) {
                line.add(fill(absRow, startCol + localCol))
            }
            rows.add(line)
        }
        return Triple(
            rows,
            maxRow >= startRow + rowCount,
            maxCol >= startCol + colCount,
        )
    }

    private fun cellKey(row: Int, col: Int): Long {
        return (row.toLong() shl 32) or (col.toLong() and 0xffffffffL)
    }

    private fun clipWindowCell(text: String): String {
        if (text.isEmpty()) return ""
        val clean = if (text.indexOf('\u0000') >= 0) text.replace("\u0000", "") else text
        return if (clean.length <= windowCellChars) clean else clean.substring(0, windowCellChars)
    }

    private fun appendCapped(into: StringBuilder, chunk: String?) {
        if (chunk.isNullOrEmpty() || into.length >= windowCellChars) return
        val room = windowCellChars - into.length
        if (chunk.length <= room) into.append(chunk) else into.append(chunk, 0, room)
    }

    private fun plainNumber(value: Double): String {
        if (value.isNaN() || value.isInfinite()) return ""
        val asLong = value.toLong()
        if (kotlin.math.abs(value) < 1.0e15 && value == asLong.toDouble()) {
            return asLong.toString()
        }
        return value.toString()
    }

    private fun parseA1(ref: String): Pair<Int, Int>? {
        val cleaned = ref.replace("$", "")
        var index = 0
        var col = 0
        while (index < cleaned.length) {
            val ch = cleaned[index]
            if (ch !in 'A'..'Z' && ch !in 'a'..'z') break
            val letter = if (ch in 'a'..'z') ch - 'a' else ch - 'A'
            col = col * 26 + letter + 1
            if (col > 200_000) return null
            index++
        }
        if (index == 0 || index >= cleaned.length) return null
        var row = 0
        while (index < cleaned.length) {
            val ch = cleaned[index]
            if (ch !in '0'..'9') return null
            row = row * 10 + (ch - '0')
            if (row > 2_000_000) return null
            index++
        }
        if (row <= 0) return null
        return (col - 1) to (row - 1)
    }

    private fun isOversizedRecord(t: Throwable): Boolean {
        var current: Throwable? = t
        var depth = 0
        while (current != null && depth < 8) {
            if (current is OutOfMemoryError) return true
            if (current.javaClass.name.endsWith("RecordFormatException")) return true
            val message = current.message.orEmpty()
            if (message.contains("maximum length", ignoreCase = true) ||
                message.contains("Tried to allocate", ignoreCase = true) ||
                message.contains("array of length", ignoreCase = true)
            ) {
                return true
            }
            current = current.cause
            depth++
        }
        return false
    }

    private fun newPullParser(input: InputStream): XmlPullParser {
        val factory = XmlPullParserFactory.newInstance()
        factory.isNamespaceAware = false
        val parser = factory.newPullParser()
        try {
            parser.setFeature("http://xmlpull.org/v1/doc/features.html#process-docdecl", false)
        } catch (_: Exception) {
        }
        parser.setInput(InputStreamReader(input, StandardCharsets.UTF_8))
        return parser
    }

    private fun xmlLocalName(parser: XmlPullParser): String {
        val name = parser.name ?: return ""
        val colon = name.lastIndexOf(':')
        return if (colon >= 0) name.substring(colon + 1) else name
    }

    private fun xmlAttr(parser: XmlPullParser, local: String): String? {
        for (i in 0 until parser.attributeCount) {
            val name = parser.getAttributeName(i) ?: continue
            val colon = name.lastIndexOf(':')
            val bare = if (colon >= 0) name.substring(colon + 1) else name
            if (bare == local) return parser.getAttributeValue(i)
        }
        return null
    }

    private fun workbookZipEntry(zip: ZipFile): ZipEntry? {
        var fallback: ZipEntry? = null
        val entries = zip.entries()
        while (entries.hasMoreElements()) {
            val entry = entries.nextElement()
            if (entry.isDirectory) continue
            val name = entry.name.replace('\\', '/')
            if (name.contains("/_rels/")) continue
            if (name == "xl/workbook.xml") return entry
            if (name == "workbook.xml" || name.endsWith("/workbook.xml")) fallback = entry
        }
        return fallback
    }

    private fun findZipEntry(zip: ZipFile, accept: (String) -> Boolean): ZipEntry? {
        val entries = zip.entries()
        while (entries.hasMoreElements()) {
            val entry = entries.nextElement()
            if (entry.isDirectory) continue
            val name = entry.name.replace('\\', '/')
            if (accept(name)) return entry
        }
        return null
    }

    private fun zipEntryExact(zip: ZipFile, path: String): ZipEntry? {
        val normalized = path.trim().trimStart('/').replace('\\', '/')
        if (normalized.isEmpty()) return null
        zip.getEntry(normalized)?.let { return it }
        return findZipEntry(zip) { it == normalized }
    }

    private fun workbookRelsPath(workbookPath: String): String {
        val slash = workbookPath.lastIndexOf('/')
        val dir = if (slash >= 0) workbookPath.substring(0, slash) else ""
        val file = if (slash >= 0) workbookPath.substring(slash + 1) else workbookPath
        return if (dir.isEmpty()) "_rels/$file.rels" else "$dir/_rels/$file.rels"
    }

    private fun resolveZipTarget(basePath: String, target: String): String {
        val decoded = try {
            URLDecoder.decode(target.trim(), StandardCharsets.UTF_8)
        } catch (_: Exception) {
            target.trim()
        }
        val cleaned = decoded.replace('\\', '/')
        if (cleaned.startsWith("/")) return cleaned.trimStart('/')
        val slash = basePath.lastIndexOf('/')
        val dir = if (slash >= 0) basePath.substring(0, slash) else ""
        val parts = ArrayList<String>()
        if (dir.isNotEmpty()) {
            for (part in dir.split('/')) {
                if (part.isNotEmpty()) parts.add(part)
            }
        }
        for (part in cleaned.split('/')) {
            when (part) {
                "", "." -> {}
                ".." -> if (parts.isNotEmpty()) parts.removeAt(parts.lastIndex)
                else -> parts.add(part)
            }
        }
        return parts.joinToString("/")
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
