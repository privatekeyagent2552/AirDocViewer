package com.airdocsviewer

import android.content.Intent
import android.content.ActivityNotFoundException
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.ByteArrayOutputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.PrintWriter
import java.io.StringWriter

class MainActivity : FlutterActivity() {
    private fun logCauseChain(prefix: String, throwable: Throwable?) {
        var current = throwable
        var depth = 0
        while (current != null && depth < 12) {
            Log.e(TAG, "$prefix cause[$depth]: ${current::class.java.name}: ${current.message}")
            current = current.cause
            depth += 1
        }
    }

    private fun logClassProbe(className: String) {
        try {
            val clazz = Class.forName(className)
            Log.i(TAG, "Class probe OK: $className from ${clazz.protectionDomain?.codeSource?.location}")
        } catch (t: Throwable) {
            Log.e(TAG, "Class probe FAILED: $className", t)
            logCauseChain("Class probe FAILED: $className", t)
        }
    }

    override fun provideFlutterEngine(context: android.content.Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get("air_docs_viewer_engine")
    }

    private val CHANNEL = "com.airdocsviewer/document_parser"
    private val FILE_CHANNEL = "com.airdocsviewer/file_intent"
    private val PDF_CHANNEL = "com.airdocsviewer/pdf"
    private val TAG = "AirDocsViewer.DocumentParser"
    private var pendingFileIntent: String? = null
    private var intentFlutterEngine: FlutterEngine? = null

    private val pdfRenderers = mutableMapOf<String, PdfRenderer>()
    private val pdfDescriptors = mutableMapOf<String, ParcelFileDescriptor>()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intentFlutterEngine = flutterEngine
        setupMethodChannels(flutterEngine)
        handleFileIntent(intent)
    }

    private fun setupMethodChannels(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                Thread {
                    try {
                        when (call.method) {
                            "parseDocument" -> {
                                val filePath = call.argument<String>("filePath")
                                val format = call.argument<String>("format")
                                val maxRows = call.argument<Int>("maxRows")
                                val maxCols = call.argument<Int>("maxCols")
                                val maxSheets = call.argument<Int>("maxSheets")

                                if (filePath == null ||
                                    !SecurityUtils.isSafeReadablePath(filePath, packageName)
                                ) {
                                    runOnUiThread {
                                        result.error(
                                            "SECURITY_ERROR",
                                            "Unsupported or unsafe file path",
                                            null,
                                        )
                                    }
                                    return@Thread
                                }

                                Log.i(TAG, "parseDocument invoked format=$format")
                                logClassProbe("com.airdocsviewer.NativeDocumentParser")
                                logClassProbe("org.apache.logging.log4j.LogManager")
                                logClassProbe("org.apache.poi.util.IOUtils")
                                logClassProbe("org.apache.poi.poifs.filesystem.FileMagic")
                                logClassProbe("org.apache.poi.hssf.usermodel.HSSFWorkbook")
                                logClassProbe("org.apache.poi.hwpf.HWPFDocument")
                                logClassProbe("org.apache.poi.xwpf.usermodel.XWPFDocument")

                                val parserClass = Class.forName("com.airdocsviewer.NativeDocumentParser")
                                val parserInstance = parserClass.getConstructor(String::class.java).newInstance(TAG)
                                val method = parserClass.getDeclaredMethod("handleParseDocument",
                                    String::class.java,
                                    String::class.java,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    MethodChannel.Result::class.java,
                                    android.app.Activity::class.java)
                                method.invoke(parserInstance, filePath, format, maxRows, maxCols, maxSheets, result, this@MainActivity)
                            }
                            "isAvailable" -> runOnUiThread { result.success(true) }
                            else -> runOnUiThread { result.notImplemented() }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Reflection load failed", e)
                        logCauseChain("Reflection load failed", e)
                        runOnUiThread { result.error("REFLECTION_ERROR", e.message, null) }
                    }
                }.start()
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getOpenFileIntent") {
                    result.success(pendingFileIntent?.let { mapOf("filePath" to it) })
                    pendingFileIntent = null
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PDF_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "renderPage" -> renderPdfPage(
                        call.argument("filePath"),
                        call.argument("pageNumber") ?: 0,
                        call.argument("width") ?: 800,
                        call.argument("height"),
                        result,
                    )
                    "openPdf" -> openPdf(call.argument("filePath"), result)
                    "closePdf" -> closePdf(call.argument("filePath"), result)
                    "getPageCount" -> getPdfPageCount(call.argument("filePath"), result)
                    "extractPageText" -> Thread {
                        try {
                            val extractorClass = Class.forName("com.airdocsviewer.PdfTextExtractor")
                            val extractorInstance = extractorClass.getConstructor(String::class.java).newInstance(TAG)
                            val method = extractorClass.getDeclaredMethod("extractPdfPageText",
                                String::class.java, Int::class.java, MethodChannel.Result::class.java, android.app.Activity::class.java)
                            method.invoke(extractorInstance, call.argument<String>("filePath"), call.argument<Int>("pageNumber") ?: 1, result, this@MainActivity)
                        } catch (e: Exception) {
                            runOnUiThread { result.error("REFLECTION_ERROR", e.message, null) }
                        }
                    }.start()
                    "extractTextWithPositions" -> Thread {
                        try {
                            val extractorClass = Class.forName("com.airdocsviewer.PdfTextExtractor")
                            val extractorInstance = extractorClass.getConstructor(String::class.java).newInstance(TAG)
                            val method = extractorClass.getDeclaredMethod("extractTextWithPositions",
                                String::class.java, Int::class.java, MethodChannel.Result::class.java, android.app.Activity::class.java)
                            method.invoke(extractorInstance, call.argument<String>("filePath"), call.argument<Int>("pageNumber") ?: 1, result, this@MainActivity)
                        } catch (e: Exception) {
                            runOnUiThread { result.error("REFLECTION_ERROR", e.message, null) }
                        }
                    }.start()
                    "getPageSize" -> getPageSize(call.argument("filePath"), call.argument("pageNumber") ?: 0, result)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.airdocsviewer/app_settings")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openManageAllFilesSettings" -> {
                        openManageAllFilesSettings()
                        result.success(null)
                    }
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.airdocsviewer/video")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractVideoFrame" -> Thread {
                        try {
                            val filePath = call.argument<String>("filePath")
                            // Handle both Int and Long from Flutter (small ints come as Int)
                            val timeUs = (call.argument<Any>("timeUs") as? Number)?.toLong() ?: 0L
                            
                            if (filePath == null) {
                                runOnUiThread { result.error("INVALID_PATH", "File path is required", null) }
                                return@Thread
                            }
                            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                                runOnUiThread {
                                    result.error("SECURITY_ERROR", "Unsupported or unsafe file path", null)
                                }
                                return@Thread
                            }

                            val bitmap = extractFirstVideoFrame(filePath, timeUs)
                            if (bitmap != null) {
                                val stream = ByteArrayOutputStream()
                                bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
                                val frameBytes = stream.toByteArray()
                                stream.close()
                                bitmap.recycle()
                                runOnUiThread { result.success(frameBytes) }
                            } else {
                                runOnUiThread { result.error("EXTRACTION_FAILED", "Failed to extract video frame", null) }
                            }
                        } catch (e: Exception) {
                            Log.e(TAG, "Video frame extraction failed", e)
                            runOnUiThread { result.error("EXTRACTION_ERROR", e.message, null) }
                        }
                    }.start()
                    else -> result.notImplemented()
                }
            }
    }

    private fun extractFirstVideoFrame(filePath: String, timeUs: Long = 0L): Bitmap? {
        return try {
            val retriever = android.media.MediaMetadataRetriever()
            retriever.setDataSource(filePath)
            val bitmap = retriever.getFrameAtTime(timeUs, android.media.MediaMetadataRetriever.OPTION_CLOSEST)
            retriever.release()
            bitmap
        } catch (e: Exception) {
            Log.e(TAG, "Failed to extract video frame from $filePath", e)
            null
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        pdfRenderers.values.forEach { it.close() }
        pdfDescriptors.values.forEach { it.close() }
        pdfRenderers.clear()
        pdfDescriptors.clear()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleFileIntent(intent)
    }

    private fun openManageAllFilesSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            openApplicationDetailsSettings()
            Log.i(TAG, "Opened app settings (Android < 11)")
            return
        }

        if (Environment.isExternalStorageManager()) {
            Log.i(TAG, "MANAGE_EXTERNAL_STORAGE already granted for $packageName")
            openApplicationDetailsSettings()
            return
        }

        val uri = Uri.fromParts("package", packageName, null)
        val appSpecificIntent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, uri)
        val genericAllFilesIntent = Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)

        try {
            startActivity(appSpecificIntent)
            Log.i(TAG, "Opened MANAGE_APP_ALL_FILES_ACCESS_PERMISSION for $packageName")
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "App-specific all files settings unavailable, opening generic page", e)
            try {
                startActivity(genericAllFilesIntent)
                Log.i(TAG, "Opened MANAGE_ALL_FILES_ACCESS_PERMISSION page")
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to open all files access screens, using app details", e2)
                openApplicationDetailsSettings()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open app-specific all files settings, using fallback", e)
            try {
                startActivity(genericAllFilesIntent)
                Log.i(TAG, "Opened MANAGE_ALL_FILES_ACCESS_PERMISSION page")
            } catch (e2: Exception) {
                Log.e(TAG, "Failed to open all files access screens, using app details", e2)
                openApplicationDetailsSettings()
            }
        }
    }

    private fun openApplicationDetailsSettings() {
        try {
            val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:$packageName")
            }
            startActivity(appDetailsIntent)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open app details settings", e)
        }
    }

    private fun handleFileIntent(intent: Intent?) {
        if (intent == null) return
        Thread {
            try {
                when (intent.action) {
                    Intent.ACTION_VIEW -> {
                        val uri = intent.data
                        if (uri != null) {
                            val filePath = getFilePathFromUri(uri)
                            if (filePath != null) {
                                Log.i(TAG, "File intent detected: $filePath")
                                pendingFileIntent = filePath
                                pushFileIntentToFlutter(filePath)
                            } else {
                                Log.w(TAG, "Could not resolve URI: $uri")
                            }
                        }
                    }
                    Intent.ACTION_SEND -> {
                        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                        if (uri != null) {
                            val filePath = getFilePathFromUri(uri)
                            if (filePath != null) {
                                Log.i(TAG, "Share intent detected: $filePath")
                                pendingFileIntent = filePath
                                pushFileIntentToFlutter(filePath)
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error handling file intent", e)
            }
        }.start()
    }

    private fun pushFileIntentToFlutter(filePath: String) {
        runOnUiThread {
            try {
                val engine = intentFlutterEngine ?: FlutterEngineCache.getInstance().get("air_docs_viewer_engine")
                if (engine != null) {
                    MethodChannel(engine.dartExecutor.binaryMessenger, FILE_CHANNEL)
                        .invokeMethod("onFileIntent", filePath)
                    Log.i(TAG, "Pushed file intent to Flutter: $filePath")
                } else {
                    Log.d(TAG, "Flutter engine not ready, intent stored for polling")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to push file intent to Flutter", e)
            }
        }
    }

    /// Resolve a content:// or file:// URI to a local file path.
    /// For content:// URIs, imports the file into the app's managed storage.
    /// For file:// URIs, returns the direct path.
    private fun getFilePathFromUri(uri: Uri): String? {
        return when {
            uri.scheme == "file" -> {
                val path = uri.path ?: return null
                if (!SecurityUtils.isSafeReadablePath(path, packageName)) {
                    Log.w(TAG, "Rejected unsafe file URI")
                    null
                } else {
                    path
                }
            }
            uri.scheme == "content" -> importContentUri(uri)
            else -> {
                Log.w(TAG, "Unsupported URI scheme: ${uri.scheme}")
                null
            }
        }
    }

    /// Maps file extension to the app's managed storage category folder name.
    /// Must match StorageService._getCategoryFromExtension() in Dart.
    private fun getCategoryFromExtension(ext: String): String {
        return when (ext.lowercase()) {
            "pdf" -> "PDFs"
            "epub", "ott" -> "Documents"
            "xlsx", "xls", "ods", "csv" -> "Spreadsheets"
            "ppt", "pptx", "odp" -> "Presentations"
            "jpg", "jpeg", "png", "gif", "webp", "ico", "psd" -> "Images"
            // Audio formats
            "aac", "mp3", "wav", "ogg", "flac", "m4a", "wma", "opus", "aiff" -> "Audio"
            // Video formats
            "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "3gp", "m4v", "mpg", "mpeg", "fmp4" -> "Video"
            // Code folder covers: docx, doc, odt, rtf, txt, java, py, sh,
            // html, md, log, json, xml, fadrec, and any unknown
            else -> "Code"
        }
    }

    /// Import a content:// URI into the app's managed storage.
    /// This copies the file from the source (Downloads, Drive, etc.) directly
    /// into the app's scoped external storage at:
    ///   /storage/emulated/0/Android/data/{package}/files/{category}/{filename}
    ///
    /// The filePath returned matches what Flutter's StorageService expects for
    /// managed files, so cacheDocument() will see it as already-managed and skip.
    private fun importContentUri(uri: Uri): String? {
        return try {
            val inputStream = contentResolver.openInputStream(uri) ?: return null

            val guessedExt = getExtensionFromMimeType(uri)
            val fileName = SecurityUtils.sanitizeFileName(getFileNameFromUri(uri))
                ?: SecurityUtils.sanitizeFileName("import_${System.currentTimeMillis()}.$guessedExt")
                ?: run {
                    Log.w(TAG, "Rejected content URI with unsupported type")
                    inputStream.close()
                    return null
                }
            val ext = fileName.substringAfterLast('.', "").lowercase()
            if (!SecurityUtils.isSupportedExtension(ext)) {
                Log.w(TAG, "Rejected unsupported import extension: $ext")
                inputStream.close()
                return null
            }
            val category = getCategoryFromExtension(ext)

            // Write directly to managed storage
            val baseDir = getExternalFilesDir(null)
                ?: return null
            val categoryDir = File(baseDir, category)
            categoryDir.mkdirs()
            val destFile = File(categoryDir, fileName)

            // Avoid overwriting existing files (append counter)
            val finalFile = resolveFileName(destFile)
            FileOutputStream(finalFile).use { output ->
                inputStream.copyTo(output)
            }
            inputStream.close()

            Log.i(TAG, "Imported content URI to managed storage")
            finalFile.absolutePath
        } catch (e: Exception) {
            Log.e(TAG, "Failed to import content URI to managed storage", e)
            null
        }
    }

    /// If a file with the same name exists, appends a counter before the extension.
    /// e.g. "doc.pdf" → "doc (1).pdf" → "doc (2).pdf"
    private fun resolveFileName(file: File): File {
        if (!file.exists()) return file
        val name = file.nameWithoutExtension
        val ext = file.extension
        var counter = 1
        while (true) {
            val candidate = File(file.parent, "$name ($counter).$ext")
            if (!candidate.exists()) return candidate
            counter++
        }
    }

    /// Extract display name from a content:// URI using OpenableColumns
    private fun getFileNameFromUri(uri: Uri): String? {
        var name: String? = null
        try {
            val cursor = contentResolver.query(uri, null, null, null, null)
            cursor?.use {
                if (it.moveToFirst()) {
                    val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (nameIndex >= 0) {
                        name = it.getString(nameIndex)
                    }
                }
            }
        } catch (_: Exception) { }
        if (name == null) {
            name = uri.lastPathSegment
        }
        return name
    }

    /// Guess a file extension from content:// URI mime type
    private fun getExtensionFromMimeType(uri: Uri): String {
        return try {
            val mimeType = contentResolver.getType(uri) ?: return "bin"
            when {
                mimeType.contains("pdf") -> "pdf"
                mimeType.contains("spreadsheet") -> "xlsx"
                mimeType.contains("excel") -> "xls"
                mimeType.contains("csv") -> "csv"
                mimeType.contains("wordprocessing") -> "docx"
                mimeType.contains("msword") -> "doc"
                mimeType.contains("presentation") -> "pptx"
                mimeType.contains("powerpoint") -> "ppt"
                mimeType.contains("text/plain") -> "txt"
                mimeType.contains("html") -> "html"
                mimeType.contains("json") -> "json"
                mimeType.contains("xml") -> "xml"
                mimeType.contains("rtf") -> "rtf"
                mimeType.contains("image") -> "jpg"
                mimeType.contains("epub") -> "epub"
                mimeType.contains("atom") || mimeType.contains("rss") -> "atom"
                mimeType.contains("audio") || mimeType.contains("aac") -> "aac"
                mimeType.contains("mpeg") -> "mp3"
                mimeType.contains("mp4") || mimeType.contains("video") -> "mp4"
                mimeType.contains("ogg") || mimeType.contains("opus") -> "ogg"
                mimeType.contains("flac") -> "flac"
                mimeType.contains("wav") || mimeType.contains("wave") -> "wav"
                mimeType.contains("webm") -> "webm"
                mimeType.contains("matroska") -> "mkv"
                mimeType.contains("x-msvideo") || mimeType.contains("avi") -> "avi"
                mimeType.contains("quicktime") || mimeType.contains("mov") -> "mov"
                mimeType.contains("x-ms-wmv") || mimeType.contains("wmv") -> "wmv"
                mimeType.contains("x-flv") || mimeType.contains("flv") -> "flv"
                mimeType.contains("3gpp") || mimeType.contains("3gp") -> "3gp"
                else -> "bin"
            }
        } catch (_: Exception) { "bin" }
    }

    private fun openPdf(filePath: String?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return result.error("INVALID_ARGS", "Missing filePath", null)
            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                return result.error("SECURITY_ERROR", "Unsupported or unsafe file path", null)
            }
            pdfRenderers[filePath]?.close()
            pdfDescriptors[filePath]?.close()
            val file = File(filePath)
            if (!file.exists()) return result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(descriptor)
            pdfDescriptors[filePath] = descriptor
            pdfRenderers[filePath] = renderer
            result.success(mapOf("pageCount" to renderer.pageCount, "filePath" to filePath))
        } catch (e: Exception) {
            Log.e(TAG, "Error opening PDF", e)
            result.error("PDF_ERROR", e.message, null)
        }
    }

    private fun closePdf(filePath: String?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return result.error("INVALID_ARGS", "Missing filePath", null)
            pdfRenderers[filePath]?.close()
            pdfDescriptors[filePath]?.close()
            pdfRenderers.remove(filePath)
            pdfDescriptors.remove(filePath)
            result.success(true)
        } catch (e: Exception) {
            Log.e(TAG, "Error closing PDF", e)
            result.error("PDF_ERROR", e.message, null)
        }
    }

    private fun renderPdfPage(filePath: String?, pageNumber: Int, width: Int, height: Int?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return result.error("INVALID_ARGS", "Missing filePath", null)
            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                return result.error("SECURITY_ERROR", "Unsupported or unsafe file path", null)
            }
            var renderer = pdfRenderers[filePath]
            if (renderer == null) {
                val file = File(filePath)
                if (!file.exists()) return result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(descriptor)
                pdfDescriptors[filePath] = descriptor
                pdfRenderers[filePath] = renderer
            }
            if (pageNumber < 0 || pageNumber >= renderer.pageCount) return result.error("INVALID_PAGE", "Invalid page number: $pageNumber", null)
            val page = renderer.openPage(pageNumber)
            val dpiScale = 2.0f
            val renderWidth = (width * dpiScale).toInt()
            val requestedHeight = height?.let { (it * dpiScale).toInt() }
            val scale = renderWidth.toFloat() / page.width
            val scaledHeight = (page.height * scale).toInt()
            val renderHeight = requestedHeight ?: scaledHeight
            val bitmap = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_PRINT)
            page.close()
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            val bytes = stream.toByteArray()
            bitmap.recycle()
            result.success(mapOf("bytes" to bytes, "width" to renderWidth, "height" to renderHeight, "pageNumber" to pageNumber))
        } catch (e: Exception) {
            Log.e(TAG, "Error rendering PDF page", e)
            result.error("PDF_RENDER_ERROR", e.message, null)
        }
    }

    private fun getPageSize(filePath: String?, pageNumber: Int, result: MethodChannel.Result) {
        try {
            if (filePath == null) return result.error("INVALID_ARGS", "Missing filePath", null)
            var renderer = pdfRenderers[filePath]
            if (renderer == null) {
                val file = File(filePath)
                if (!file.exists()) return result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(descriptor)
                pdfDescriptors[filePath] = descriptor
                pdfRenderers[filePath] = renderer
            }
            if (pageNumber < 0 || pageNumber >= renderer.pageCount) return result.error("INVALID_PAGE", "Invalid page number: $pageNumber", null)
            val page = renderer.openPage(pageNumber)
            val width = page.width
            val height = page.height
            page.close()
            result.success(mapOf("width" to width, "height" to height))
        } catch (e: Exception) {
            Log.e(TAG, "Error getting page size", e)
            result.error("PDF_ERROR", e.message, null)
        }
    }

    private fun getPdfPageCount(filePath: String?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return result.error("INVALID_ARGS", "Missing filePath", null)
            val file = File(filePath)
            if (!file.exists()) return result.error("FILE_NOT_FOUND", "File not found: $filePath", null)
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(descriptor)
            val count = renderer.pageCount
            renderer.close()
            descriptor.close()
            result.success(count)
        } catch (e: Exception) {
            Log.e(TAG, "PDF page count error", e)
            result.error("PDF_ERROR", e.message, null)
        }
    }
}
