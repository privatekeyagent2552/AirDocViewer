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
                val text = textStripper.getText(document)
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
            
        } catch (e: Exception) {
            Log.e(TAG, "PDF page text extraction error", e)
            activity.runOnUiThread { result.error("PDF_ERROR", e.message, null) }
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
                val text = stripper.getText(document)
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
        } catch (e: Exception) {
            Log.e(TAG, "PDF text position extraction error", e)
            activity.runOnUiThread { result.error("PDF_ERROR", e.message, null) }
        }
    }

    companion object {
        private const val MAX_PDF_BYTES = 32L * 1024 * 1024
        private const val MAX_POSITIONS = 20_000
    }
}
