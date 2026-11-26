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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import kotlin.math.sqrt

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

    /** One heavy job at a time so POI, PDFBox, and bitmaps cannot stack to the 512MB heap. */
    private fun succeed(result: MethodChannel.Result, value: Any?) {
        runOnUiThread {
            try {
                result.success(value)
            } catch (t: Throwable) {
                Log.e(TAG, "result.success failed", t)
                try {
                    result.error("PDF_ERROR", "This file could not be opened.", null)
                } catch (_: Throwable) {
                }
            }
        }
    }

    private fun fail(result: MethodChannel.Result, code: String, message: String?) {
        runOnUiThread {
            try {
                result.error(code, message, null)
            } catch (t: Throwable) {
                Log.e(TAG, "result.error failed", t)
            }
        }
    }

    private fun pdfFailureMessage(t: Throwable): String {
        val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
        val text = t.message.orEmpty()
        return if (oom || text.contains("too large", ignoreCase = true)) {
            "This file is too large to open completely on this device."
        } else {
            "This file could not be opened."
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intentFlutterEngine = flutterEngine
        setupMethodChannels(flutterEngine)
        handleFileIntent(intent)
    }

    private fun setupMethodChannels(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                heavyExecutor.execute {
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
                                    return@execute
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
                            "readPptxSlide", "readPptSlide" -> {
                                val filePath = call.argument<String>("filePath")
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
                                    return@execute
                                }
                                val parserClass = Class.forName("com.airdocsviewer.NativeDocumentParser")
                                val parserInstance = parserClass
                                    .getConstructor(String::class.java)
                                    .newInstance(TAG)
                                if (call.method == "readPptxSlide") {
                                    val method = parserClass.getDeclaredMethod(
                                        "handleReadPptxSlide",
                                        String::class.java,
                                        Int::class.javaObjectType,
                                        String::class.java,
                                        String::class.java,
                                        MethodChannel.Result::class.java,
                                        android.app.Activity::class.java,
                                    )
                                    method.invoke(
                                        parserInstance,
                                        filePath,
                                        call.argument<Int>("index") ?: 0,
                                        call.argument<String>("mediaDir"),
                                        call.argument<String>("packagePath"),
                                        result,
                                        this@MainActivity,
                                    )
                                } else {
                                    val method = parserClass.getDeclaredMethod(
                                        "handleReadPptSlide",
                                        String::class.java,
                                        Int::class.javaObjectType,
                                        MethodChannel.Result::class.java,
                                        android.app.Activity::class.java,
                                    )
                                    method.invoke(
                                        parserInstance,
                                        filePath,
                                        call.argument<Int>("index") ?: 0,
                                        result,
                                        this@MainActivity,
                                    )
                                }
                            }
                            "readWordWindow" -> {
                                val filePath = call.argument<String>("filePath")
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
                                    return@execute
                                }
                                val parserClass = Class.forName("com.airdocsviewer.NativeDocumentParser")
                                val parserInstance = parserClass
                                    .getConstructor(String::class.java)
                                    .newInstance(TAG)
                                val method = parserClass.getDeclaredMethod(
                                    "handleReadWordWindow",
                                    String::class.java,
                                    String::class.java,
                                    Int::class.javaObjectType,
                                    MethodChannel.Result::class.java,
                                    android.app.Activity::class.java,
                                )
                                method.invoke(
                                    parserInstance,
                                    filePath,
                                    call.argument<String>("format"),
                                    call.argument<Int>("start") ?: 0,
                                    result,
                                    this@MainActivity,
                                )
                            }
                            "readSheetWindow" -> {
                                val filePath = call.argument<String>("filePath")
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
                                    return@execute
                                }
                                val parserClass = Class.forName("com.airdocsviewer.NativeDocumentParser")
                                val parserInstance = parserClass
                                    .getConstructor(String::class.java)
                                    .newInstance(TAG)
                                val method = parserClass.getDeclaredMethod(
                                    "handleReadSheetWindow",
                                    String::class.java,
                                    String::class.java,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    Int::class.javaObjectType,
                                    MethodChannel.Result::class.java,
                                    android.app.Activity::class.java,
                                )
                                method.invoke(
                                    parserInstance,
                                    filePath,
                                    call.argument<String>("format"),
                                    call.argument<Int>("sheetIndex") ?: 0,
                                    call.argument<Int>("startRow") ?: 0,
                                    call.argument<Int>("rowCount") ?: 200,
                                    call.argument<Int>("startCol") ?: 0,
                                    call.argument<Int>("colCount") ?: 30,
                                    result,
                                    this@MainActivity,
                                )
                            }
                            "isAvailable" -> runOnUiThread { result.success(true) }
                            else -> runOnUiThread { result.notImplemented() }
                        }
                    } catch (t: Throwable) {
                        Log.e(TAG, "Reflection load failed", t)
                        logCauseChain("Reflection load failed", t)
                        val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
                        val message = if (oom) {
                            "This file is too large to open completely on this device."
                        } else {
                            "This file could not be opened."
                        }
                        runOnUiThread {
                            try {
                                result.error(
                                    if (oom) "PARSE_ERROR" else "REFLECTION_ERROR",
                                    message,
                                    null,
                                )
                            } catch (replyFailure: Throwable) {
                                Log.e(TAG, "result.error failed", replyFailure)
                            }
                        }
                    }
                }
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
                heavyExecutor.execute {
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
                        "extractPageText" -> {
                            try {
                                val extractorClass = Class.forName("com.airdocsviewer.PdfTextExtractor")
                                val extractorInstance = extractorClass.getConstructor(String::class.java).newInstance(TAG)
                                val method = extractorClass.getDeclaredMethod(
                                    "extractPdfPageText",
                                    String::class.java,
                                    Int::class.java,
                                    MethodChannel.Result::class.java,
                                    android.app.Activity::class.java,
                                )
                                method.invoke(
                                    extractorInstance,
                                    call.argument<String>("filePath"),
                                    call.argument<Int>("pageNumber") ?: 1,
                                    result,
                                    this@MainActivity,
                                )
                            } catch (t: Throwable) {
                                val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
                                Log.e(TAG, "extractPageText failed", t)
                                fail(
                                    result,
                                    if (oom) "PDF_ERROR" else "REFLECTION_ERROR",
                                    if (oom) {
                                        "This page has too much text to extract on this device."
                                    } else {
                                        "This file could not be opened."
                                    },
                                )
                            }
                        }
                        "extractTextWithPositions" -> {
                            try {
                                val extractorClass = Class.forName("com.airdocsviewer.PdfTextExtractor")
                                val extractorInstance = extractorClass.getConstructor(String::class.java).newInstance(TAG)
                                val method = extractorClass.getDeclaredMethod(
                                    "extractTextWithPositions",
                                    String::class.java,
                                    Int::class.java,
                                    MethodChannel.Result::class.java,
                                    android.app.Activity::class.java,
                                )
                                method.invoke(
                                    extractorInstance,
                                    call.argument<String>("filePath"),
                                    call.argument<Int>("pageNumber") ?: 1,
                                    result,
                                    this@MainActivity,
                                )
                            } catch (t: Throwable) {
                                val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
                                Log.e(TAG, "extractTextWithPositions failed", t)
                                fail(
                                    result,
                                    if (oom) "PDF_ERROR" else "REFLECTION_ERROR",
                                    if (oom) {
                                        "This page has too much text to extract on this device."
                                    } else {
                                        "This file could not be opened."
                                    },
                                )
                            }
                        }
                        "getPageSize" -> getPageSize(call.argument("filePath"), call.argument("pageNumber") ?: 0, result)
                        else -> runOnUiThread { result.notImplemented() }
                    }
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
                    "extractVideoFrame" -> heavyExecutor.execute {
                        try {
                            val filePath = call.argument<String>("filePath")
                            // Handle both Int and Long from Flutter (small ints come as Int)
                            val timeUs = (call.argument<Any>("timeUs") as? Number)?.toLong() ?: 0L
                            
                            if (filePath == null) {
                                runOnUiThread { result.error("INVALID_PATH", "File path is required", null) }
                                return@execute
                            }
                            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                                runOnUiThread {
                                    result.error("SECURITY_ERROR", "Unsupported or unsafe file path", null)
                                }
                                return@execute
                            }

                            val bitmap = extractFirstVideoFrame(filePath, timeUs)
                            if (bitmap != null) {
                                val scaled = scaleBitmapDown(bitmap, 720)
                                val stream = ByteArrayOutputStream()
                                scaled.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                                val frameBytes = stream.toByteArray()
                                stream.close()
                                if (scaled !== bitmap) scaled.recycle()
                                bitmap.recycle()
                                runOnUiThread { result.success(frameBytes) }
                            } else {
                                runOnUiThread { result.error("EXTRACTION_FAILED", "Failed to extract video frame", null) }
                            }
                        } catch (t: Throwable) {
                            Log.e(TAG, "Video frame extraction failed", t)
                            val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
                            runOnUiThread {
                                try {
                                    result.error(
                                        if (oom) "PARSE_ERROR" else "EXTRACTION_ERROR",
                                        if (oom) {
                                            "This file is too large to open completely on this device."
                                        } else {
                                            "This file could not be opened."
                                        },
                                        null,
                                    )
                                } catch (_: Throwable) {
                                }
                            }
                        }
                    }
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
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to extract video frame from $filePath", t)
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
            "docx", "doc", "odt", "rtf", "txt", "html", "htm", "md", "log",
            "json", "xml", "atom", "epub", "ott", "fadrec" -> "Documents"
            "xlsx", "xls", "ods", "csv" -> "Spreadsheets"
            "ppt", "pptx", "odp" -> "Presentations"
            "jpg", "jpeg", "png", "gif", "webp", "ico", "psd",
            "bmp", "svg", "tif", "tiff", "heic", "heif", "avif" -> "Images"
            "aac", "mp3", "wav", "ogg", "flac", "m4a", "wma", "opus", "aiff" -> "Audio"
            "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "3gp", "m4v",
            "mpg", "mpeg", "fmp4" -> "Video"
            else -> "Documents"
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

            // Peek magic bytes before writing (prevent EXE renamed to .pdf etc.)
            val peek = ByteArray(64)
            val read = inputStream.read(peek)
            inputStream.close()
            if (read <= 0) {
                Log.w(TAG, "Rejected empty content URI stream")
                return null
            }
            if (!SecurityUtils.validateStreamHeader(peek.inputStream(), ext)) {
                Log.w(TAG, "Rejected content URI — magic/signature mismatch for .$ext")
                return null
            }

            val fullStream = contentResolver.openInputStream(uri) ?: return null
            val category = getCategoryFromExtension(ext)

            // Write directly to managed storage
            val baseDir = getExternalFilesDir(null)
                ?: return null
            val categoryDir = File(baseDir, category)
            categoryDir.mkdirs()
            val destFile = File(categoryDir, fileName)

            // Avoid overwriting existing files (append counter)
            val finalFile = resolveFileName(destFile)
            try {
                FileOutputStream(finalFile).use { output ->
                    fullStream.copyTo(output)
                }
            } finally {
                fullStream.close()
            }

            if (!SecurityUtils.validateFileContent(finalFile)) {
                Log.w(TAG, "Post-write validation failed — deleting import")
                finalFile.delete()
                return null
            }

            Log.i(TAG, "Imported content URI to managed storage")
            finalFile.absolutePath
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to import content URI to managed storage", t)
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
            if (filePath == null) return fail(result, "INVALID_ARGS", "Missing filePath")
            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                return fail(result, "SECURITY_ERROR", "Unsupported or unsafe file path")
            }
            pdfRenderers[filePath]?.close()
            pdfDescriptors[filePath]?.close()
            val file = File(filePath)
            if (!file.exists()) return fail(result, "FILE_NOT_FOUND", "File not found: $filePath")
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(descriptor)
            pdfDescriptors[filePath] = descriptor
            pdfRenderers[filePath] = renderer
            succeed(result, mapOf("pageCount" to renderer.pageCount, "filePath" to filePath))
        } catch (t: Throwable) {
            Log.e(TAG, "Error opening PDF", t)
            fail(result, "PDF_ERROR", pdfFailureMessage(t))
        }
    }

    private fun closePdf(filePath: String?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return fail(result, "INVALID_ARGS", "Missing filePath")
            pdfRenderers[filePath]?.close()
            pdfDescriptors[filePath]?.close()
            pdfRenderers.remove(filePath)
            pdfDescriptors.remove(filePath)
            succeed(result, true)
        } catch (t: Throwable) {
            Log.e(TAG, "Error closing PDF", t)
            fail(result, "PDF_ERROR", pdfFailureMessage(t))
        }
    }

    private fun renderPdfPage(filePath: String?, pageNumber: Int, width: Int, height: Int?, result: MethodChannel.Result) {
        var descriptor: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        var page: PdfRenderer.Page? = null
        var bitmap: Bitmap? = null
        try {
            if (filePath == null) return fail(result, "INVALID_ARGS", "Missing filePath")
            if (!SecurityUtils.isSafeReadablePath(filePath, packageName)) {
                return fail(result, "SECURITY_ERROR", "Unsupported or unsafe file path")
            }
            val file = File(filePath)
            if (!file.exists()) return fail(result, "FILE_NOT_FOUND", "File not found: $filePath")
            descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(descriptor)
            if (pageNumber < 0 || pageNumber >= renderer.pageCount) {
                return fail(result, "INVALID_PAGE", "Invalid page number: $pageNumber")
            }
            page = renderer.openPage(pageNumber)
            var renderWidth = (width * 2f).roundToInt().coerceAtLeast(1)
            val requestedHeight = height?.let { (it * 2f).roundToInt().coerceAtLeast(1) }
            val scale = renderWidth.toFloat() / page.width.coerceAtLeast(1)
            val scaledHeight = (page.height * scale).roundToInt().coerceAtLeast(1)
            var renderHeight = requestedHeight ?: scaledHeight
            val pixels = renderWidth.toLong() * renderHeight.toLong()
            val maxPixels = 1024L * 1024L
            if (pixels > maxPixels) {
                val down = sqrt(maxPixels.toDouble() / pixels.toDouble())
                renderWidth = (renderWidth * down).roundToInt().coerceAtLeast(1)
                renderHeight = (renderHeight * down).roundToInt().coerceAtLeast(1)
            }
            bitmap = Bitmap.createBitmap(renderWidth, renderHeight, Bitmap.Config.ARGB_8888)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, stream)
            val bytes = stream.toByteArray()
            stream.close()
            succeed(
                result,
                mapOf(
                    "bytes" to bytes,
                    "width" to renderWidth,
                    "height" to renderHeight,
                    "pageNumber" to pageNumber,
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Error rendering PDF page", t)
            val oom = generateSequence(t) { it.cause }.any { it is OutOfMemoryError }
            fail(
                result,
                "PDF_RENDER_ERROR",
                if (oom) {
                    "This page is too large to draw on this device."
                } else {
                    "This file could not be opened."
                },
            )
        } finally {
            try {
                page?.close()
            } catch (_: Throwable) {
            }
            try {
                bitmap?.recycle()
            } catch (_: Throwable) {
            }
            try {
                renderer?.close()
            } catch (_: Throwable) {
            }
            try {
                descriptor?.close()
            } catch (_: Throwable) {
            }
        }
    }

    private fun getPageSize(filePath: String?, pageNumber: Int, result: MethodChannel.Result) {
        try {
            if (filePath == null) return fail(result, "INVALID_ARGS", "Missing filePath")
            var renderer = pdfRenderers[filePath]
            if (renderer == null) {
                val file = File(filePath)
                if (!file.exists()) return fail(result, "FILE_NOT_FOUND", "File not found: $filePath")
                val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                renderer = PdfRenderer(descriptor)
                pdfDescriptors[filePath] = descriptor
                pdfRenderers[filePath] = renderer
            }
            if (pageNumber < 0 || pageNumber >= renderer.pageCount) {
                return fail(result, "INVALID_PAGE", "Invalid page number: $pageNumber")
            }
            val page = renderer.openPage(pageNumber)
            val width = page.width
            val height = page.height
            page.close()
            succeed(result, mapOf("width" to width, "height" to height))
        } catch (t: Throwable) {
            Log.e(TAG, "Error getting page size", t)
            fail(result, "PDF_ERROR", pdfFailureMessage(t))
        }
    }

    private fun getPdfPageCount(filePath: String?, result: MethodChannel.Result) {
        try {
            if (filePath == null) return fail(result, "INVALID_ARGS", "Missing filePath")
            val file = File(filePath)
            if (!file.exists()) return fail(result, "FILE_NOT_FOUND", "File not found: $filePath")
            val descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            val renderer = PdfRenderer(descriptor)
            val count = renderer.pageCount
            renderer.close()
            descriptor.close()
            succeed(result, count)
        } catch (t: Throwable) {
            Log.e(TAG, "PDF page count error", t)
            fail(result, "PDF_ERROR", pdfFailureMessage(t))
        }
    }

    private fun scaleBitmapDown(source: Bitmap, maxEdge: Int): Bitmap {
        val longest = maxOf(source.width, source.height)
        if (longest <= maxEdge || longest <= 0) return source
        val scale = maxEdge.toFloat() / longest.toFloat()
        val width = (source.width * scale).roundToInt().coerceAtLeast(1)
        val height = (source.height * scale).roundToInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, width, height, true)
    }

    companion object {
        private val heavyExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "airdocs-heavy").apply { isDaemon = true }
        }
    }
}
