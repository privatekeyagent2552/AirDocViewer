package com.airdocsviewer

import android.app.Activity
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import org.apache.poi.ss.usermodel.DataFormatter
import org.apache.poi.ss.usermodel.CellType
import org.apache.poi.ss.usermodel.WorkbookFactory
import org.apache.poi.hssf.usermodel.HSSFWorkbook
import org.apache.poi.hwpf.HWPFDocument
import org.apache.poi.hwpf.extractor.WordExtractor
import org.apache.poi.hwpf.usermodel.Paragraph as HwpfParagraph
import org.apache.poi.hwpf.usermodel.Range as HwpfRange
import org.apache.poi.xwpf.usermodel.BodyElementType
import org.apache.poi.xwpf.usermodel.IBodyElement
import org.apache.poi.xwpf.usermodel.UnderlinePatterns
import org.apache.poi.xwpf.usermodel.XWPFDocument
import org.apache.poi.xwpf.usermodel.XWPFHyperlinkRun
import org.apache.poi.xwpf.usermodel.XWPFParagraph
import org.apache.poi.xwpf.usermodel.XWPFRun
import org.apache.poi.xwpf.usermodel.XWPFTable
import org.apache.poi.xwpf.usermodel.XWPFTableCell
import org.apache.poi.xwpf.usermodel.XWPFTableRow
import org.apache.poi.sl.usermodel.SlideShowFactory
import org.apache.poi.sl.usermodel.TextShape
import java.io.File
import java.io.FileInputStream
import java.io.PrintWriter
import java.io.StringWriter

class NativeDocumentParser(private val TAG: String) {

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
            activity.runOnUiThread { result.success(data) }
        }
        fun replyError(code: String, message: String?) {
            if (replied) return
            replied = true
            activity.runOnUiThread { result.error(code, message, null) }
        }
        try {
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
        } catch (e: Exception) {
            Log.e(TAG, "Parse error", e)
            logCauseChain("Parse error", e)
            val sw = StringWriter()
            e.printStackTrace(PrintWriter(sw))
            replyError("PARSE_ERROR", "${e.message}\n${sw}")
        }
    }

    private fun parseXLSX(filePath: String, maxRows: Int?, maxCols: Int?, maxSheets: Int?): Map<String, Any> {
        logStep("parseXLSX:start")
        probeClass("org.apache.poi.ss.usermodel.WorkbookFactory")
        probeClass("org.apache.poi.poifs.filesystem.FileMagic")
        probeClass("org.apache.poi.util.IOUtils")
        val file = File(filePath)
        logStep("parseXLSX:before WorkbookFactory.create")
        val workbook = WorkbookFactory.create(file)
        logStep("parseXLSX:after WorkbookFactory.create")
        val sheets = mutableListOf<Map<String, Any>>()
        val formatter = DataFormatter()
        val evaluator = workbook.creationHelper.createFormulaEvaluator()
        val rowLimit = maxRows ?: Int.MAX_VALUE
        val colLimit = maxCols ?: Int.MAX_VALUE
        val sheetLimit = minOf(workbook.numberOfSheets, maxSheets ?: workbook.numberOfSheets)

        try {
            for (sheetIndex in 0 until sheetLimit) {
                val sheet = workbook.getSheetAt(sheetIndex)
                val rows = mutableListOf<List<String>>()

                for (rowIndex in 0 until sheet.physicalNumberOfRows) {
                    if (rows.size >= rowLimit) break

                    val row = sheet.getRow(rowIndex) ?: continue
                    val cells = mutableListOf<String>()
                    val cellCount = minOf(row.lastCellNum.toInt().coerceAtLeast(0), colLimit)

                    for (cellIndex in 0 until cellCount) {
                        val cell = row.getCell(cellIndex)
                        val cellValue = if (cell == null) "" else formatter.formatCellValue(cell, evaluator)
                        cells.add(cellValue)
                    }
                    if (cells.isNotEmpty()) rows.add(cells)
                }

                sheets.add(mapOf(
                    "name" to (sheet.sheetName ?: "Sheet $sheetIndex"),
                    "rows" to rows,
                    "rowCount" to rows.size,
                    "colCount" to (rows.firstOrNull()?.size ?: 0)
                ))
            }
        } finally {
            workbook.close()
        }

        return mapOf(
            "sheets" to sheets,
            "sheetCount" to sheets.size,
            "format" to "XLSX",
            "filePath" to filePath
        )
    }

    private fun parseXLS(filePath: String, maxRows: Int?, maxCols: Int?, maxSheets: Int?): Map<String, Any> {
        logStep("parseXLS:start")
        probeClass("org.apache.poi.hssf.usermodel.HSSFWorkbook")
        probeClass("org.apache.poi.util.IOUtils")
        val file = File(filePath)
        val fileInputStream = FileInputStream(file)
        logStep("parseXLS:before HSSFWorkbook")
        val workbook = HSSFWorkbook(fileInputStream)
        logStep("parseXLS:after HSSFWorkbook")
        val sheets = mutableListOf<Map<String, Any>>()
        val formatter = DataFormatter()
        val evaluator = workbook.creationHelper.createFormulaEvaluator()
        val rowLimit = maxRows ?: Int.MAX_VALUE
        val colLimit = maxCols ?: Int.MAX_VALUE
        val sheetLimit = minOf(workbook.numberOfSheets, maxSheets ?: workbook.numberOfSheets)

        try {
            for (sheetIndex in 0 until sheetLimit) {
                val sheet = workbook.getSheetAt(sheetIndex)
                val rows = mutableListOf<List<String>>()

                for (rowIndex in 0 until sheet.physicalNumberOfRows) {
                    if (rows.size >= rowLimit) break

                    val row = sheet.getRow(rowIndex) ?: continue
                    val cells = mutableListOf<String>()
                    val cellCount = minOf(row.lastCellNum.toInt().coerceAtLeast(0), colLimit)

                    for (cellIndex in 0 until cellCount) {
                        val cell = row.getCell(cellIndex)
                        val cellValue = if (cell == null) "" else formatter.formatCellValue(cell, evaluator)
                        cells.add(cellValue)
                    }
                    if (cells.isNotEmpty()) rows.add(cells)
                }

                sheets.add(mapOf(
                    "name" to (sheet.sheetName ?: "Sheet $sheetIndex"),
                    "rows" to rows,
                    "rowCount" to rows.size,
                    "colCount" to (rows.firstOrNull()?.size ?: 0)
                ))
            }
        } finally {
            workbook.close()
            fileInputStream.close()
        }

        return mapOf(
            "sheets" to sheets,
            "sheetCount" to sheets.size,
            "format" to "XLS",
            "filePath" to filePath
        )
    }

    private fun parsePresentation(filePath: String, format: String): Map<String, Any> {
        logStep("parsePresentation:start ($format)")
        val file = File(filePath)
        logStep("parsePresentation:before SlideShowFactory.create")
        val slideShow = SlideShowFactory.create(file, null, true)
        logStep("parsePresentation:after SlideShowFactory.create")
        try {
            val slides = mutableListOf<Map<String, Any>>()
            val documentBlocks = mutableListOf<Map<String, Any>>()
            val allText = StringBuilder()
            val warnings = linkedSetOf(
                "Presentation shows slide text, headings, and detected bullets without original layout or images.",
            )

            // Prefer HSLF/XSLF text extractors — HSLF getShapes() can crash on Android
            // (missing java.awt.*) for decks with certain tables.
            var bulkText = ""
            try {
                bulkText = extractPresentationPlainText(filePath, format)
            } catch (t: Throwable) {
                Log.w(TAG, "Bulk presentation extractor failed: ${t.message}")
            }

            var index = 1
            for (slide in slideShow.slides) {
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
            slideShow.close()
        }
    }

    /** Extract plain text without relying on shape geometry (avoids java.awt on Android). */
    private fun extractPresentationPlainText(filePath: String, format: String): String {
        return FileInputStream(File(filePath)).use { fis ->
            when (format.uppercase()) {
                "PPT" -> {
                    val clazz = Class.forName("org.apache.poi.hslf.extractor.PowerPointExtractor")
                    val extractor = clazz.getConstructor(java.io.InputStream::class.java).newInstance(fis)
                    try {
                        (clazz.getMethod("getText").invoke(extractor) as? String).orEmpty()
                    } finally {
                        try {
                            clazz.getMethod("close").invoke(extractor)
                        } catch (_: Throwable) {
                        }
                    }
                }
                else -> {
                    val pkgClass = Class.forName("org.apache.poi.openxml4j.opc.OPCPackage")
                    val open = pkgClass.getMethod("open", java.io.InputStream::class.java)
                    val pkg = open.invoke(null, fis)
                    try {
                        val clazz =
                            Class.forName("org.apache.poi.xslf.extractor.XSLFPowerPointExtractor")
                        val extractor = clazz.getConstructor(pkgClass).newInstance(pkg)
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
                            pkgClass.getMethod("revert").invoke(pkg)
                        } catch (_: Throwable) {
                            try {
                                pkgClass.getMethod("close").invoke(pkg)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
            }
        }
    }

    private fun parseCSV(filePath: String, maxRows: Int?, maxCols: Int?): Map<String, Any> {
        val file = File(filePath)
        val content = file.readText()
        val lines = content.split("\n")
        val rows = mutableListOf<List<String>>()
        val rowLimit = maxRows ?: Int.MAX_VALUE
        val colLimit = maxCols ?: Int.MAX_VALUE

        for (line in lines) {
            if (rows.size >= rowLimit) break
            if (line.trim().isEmpty()) continue

            val cells = mutableListOf<String>()
            var currentCell = StringBuilder()
            var inQuotes = false

            for (char in line) {
                when {
                    char == '"' -> inQuotes = !inQuotes
                    char == ',' && !inQuotes -> {
                        cells.add(currentCell.toString().trim())
                        currentCell = StringBuilder()
                    }
                    else -> currentCell.append(char)
                }
            }

            if (currentCell.isNotEmpty()) {
                cells.add(currentCell.toString().trim())
            }

            if (cells.isNotEmpty()) {
                rows.add(cells.take(colLimit))
            }
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
            "filePath" to filePath
        )
    }

    private fun parseDOCX(filePath: String): Map<String, Any> {
        logStep("parseDOCX:start")
        probeClass("org.apache.poi.xwpf.usermodel.XWPFDocument")
        val file = File(filePath)
        val fileInputStream = FileInputStream(file)
        logStep("parseDOCX:before XWPFDocument")
        val document = XWPFDocument(fileInputStream)
        logStep("parseDOCX:after XWPFDocument")

        try {
            val blocks = mutableListOf<Map<String, Any>>()
            val warnings = linkedSetOf<String>()

            for (element in document.bodyElements) {
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
            fileInputStream.close()
        }
    }

    private fun parseDOC(filePath: String): Map<String, Any> {
        logStep("parseDOC:start")
        probeClass("org.apache.poi.hwpf.HWPFDocument")
        probeClass("org.apache.poi.util.IOUtils")
        val file = File(filePath)
        val fileInputStream = FileInputStream(file)
        logStep("parseDOC:before HWPFDocument")
        val document = HWPFDocument(fileInputStream)
        logStep("parseDOC:after HWPFDocument")
        val extractor = WordExtractor(document)

        try {
            val text = extractor.text
            val documentBlocks = mutableListOf<Map<String, Any>>()
            val range: HwpfRange = document.range
            for (i in 0 until range.numParagraphs()) {
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
                    "Legacy DOC shows paragraphs, basic styles, and list levels when available."
                ),
                "fidelityLevel" to "partial",
                "wordCount" to wordCount,
                "lineCount" to lineCount,
                "format" to "DOC",
                "filePath" to filePath
            )
        } finally {
            extractor.close()
            document.close()
            fileInputStream.close()
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

        if (run.embeddedPictures.isNotEmpty()) {
            warnings.add("Embedded DOCX images are not fully rendered yet.")
            inlines.add(
                mapOf(
                    "type" to "text",
                    "text" to "[Image]",
                    "style" to style
                )
            )
        }

        if (runText.isEmpty() && run.embeddedPictures.isEmpty()) {
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
}
