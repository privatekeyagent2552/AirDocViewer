package com.airdocsviewer

import android.app.Activity
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition
import java.io.File

class PdfTextExtractor(private val TAG: String) {

    fun extractPdfPageText(filePath: String?, pageNumber: Int, result: MethodChannel.Result, activity: Activity) {
        try {
            if (filePath == null) {
                activity.runOnUiThread { result.error("INVALID_ARGS", "Missing filePath", null) }
                return
            }
            val file = File(filePath)
            if (!file.exists()) {
                activity.runOnUiThread { result.error("FILE_NOT_FOUND", "File not found: $filePath", null) }
                return
            }
            if (file.length() > MAX_PDF_BYTES) {
                activity.runOnUiThread {
                    result.error("PDF_ERROR", "PDF is too large to extract text safely on this device.", null)
                }
                return
            }

            val document = PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
            try {
                val textStripper = PDFTextStripper()
                textStripper.startPage = pageNumber
                textStripper.endPage = pageNumber
                val text = capPageText(textStripper.getText(document))
                activity.runOnUiThread {
                    result.success(mapOf(
                        "pageNumber" to pageNumber,
                        "text" to text
                    ))
                }
            } finally {
                document.close()
            }
            return
        } catch (_: OutOfMemoryError) {
            Log.e(TAG, "PDF page text extraction ran out of memory")
            replyPdfError(activity, result, "This page has too much text to extract on this device.")
        } catch (t: Throwable) {
            Log.e(TAG, "PDF page text extraction error", t)
            replyPdfError(activity, result, "This file could not be opened.")
        }
    }
    
    fun extractTextWithPositions(filePath: String?, pageNumber: Int, result: MethodChannel.Result, activity: Activity) {
        try {
            if (filePath == null) {
                activity.runOnUiThread { result.error("INVALID_ARGS", "Missing filePath", null) }
                return
            }
            val file = File(filePath)
            if (!file.exists()) {
                activity.runOnUiThread { result.error("FILE_NOT_FOUND", "File not found: $filePath", null) }
                return
            }
            if (file.length() > MAX_PDF_BYTES) {
                activity.runOnUiThread {
                    result.error("PDF_ERROR", "PDF is too large to extract text safely on this device.", null)
                }
                return
            }

            val document = PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
            try {
                val stripper = object : PDFTextStripper() {
                    val characters = mutableListOf<Map<String, Any>>()

                    override fun writeString(text: String, textPositions: List<TextPosition>) {
                        for (pos in textPositions) {
                            if (characters.size >= MAX_POSITIONS) break
                            characters.add(mapOf(
                                "text" to pos.unicode,
                                "x" to pos.xDirAdj,
                                "y" to pos.yDirAdj,
                                "width" to pos.widthDirAdj,
                                "height" to pos.heightDir,
                                "fontSize" to pos.fontSize
                            ))
                        }
                        super.writeString(text, textPositions)
                    }
                }

                stripper.startPage = pageNumber
                stripper.endPage = pageNumber
                val text = capPageText(stripper.getText(document))
                activity.runOnUiThread {
                    result.success(mapOf(
                        "pageNumber" to pageNumber,
                        "text" to text,
                        "characters" to stripper.characters
                    ))
                }
            } finally {
                document.close()
            }
        } catch (_: OutOfMemoryError) {
            Log.e(TAG, "PDF text position extraction ran out of memory")
            replyPdfError(activity, result, "This page has too much text to extract on this device.")
        } catch (t: Throwable) {
            Log.e(TAG, "PDF text position extraction error", t)
            replyPdfError(activity, result, "This file could not be opened.")
        }
    }

    private fun replyPdfError(activity: Activity, result: MethodChannel.Result, message: String) {
        try {
            activity.runOnUiThread {
                try {
                    result.error("PDF_ERROR", message, null)
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
        }
    }

    private fun capPageText(raw: String): String {
        if (raw.length <= MAX_PAGE_CHARS) return raw
        return raw.substring(0, MAX_PAGE_CHARS) + "\n[Page text truncated so it fits in memory.]"
    }

    companion object {
        private const val MAX_PDF_BYTES = 32L * 1024 * 1024
        private const val MAX_POSITIONS = 20_000
        private const val MAX_PAGE_CHARS = 200_000
    }
}
