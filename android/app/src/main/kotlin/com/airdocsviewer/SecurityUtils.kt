package com.airdocsviewer

import java.io.File

/**
 * Central validation for external file access (intents, imports, parsers).
 */
object SecurityUtils {
    private val SUPPORTED_EXTENSIONS = setOf(
        "pdf", "doc", "docx", "odt", "rtf", "txt", "epub", "ott",
        "xlsx", "xls", "ods", "csv",
        "ppt", "pptx", "odp",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "psd",
        "tif", "tiff", "heic", "heif", "avif",
        "aac", "mp3", "wav", "ogg", "flac", "m4a", "wma", "opus", "aiff",
        "mp4", "avi", "mkv", "mov", "wmv", "flv", "webm", "3gp", "m4v", "mpg", "mpeg", "fmp4",
        "java", "py", "sh", "bash", "html", "htm", "md", "log", "json", "xml", "fadrec", "atom",
        "dart", "kt", "kts", "js", "ts", "jsx", "tsx", "c", "cpp", "h", "hpp", "cs",
        "php", "rb", "swift", "go", "rs", "sql", "yaml", "yml", "toml", "gradle",
        "properties", "ini", "conf", "bat", "cmd", "ps1", "r",
    )

    private val BLOCKED_PATH_PREFIXES = listOf(
        "/system/",
        "/proc/",
        "/sys/",
        "/dev/",
    )

    fun isSupportedExtension(ext: String): Boolean =
        ext.lowercase() in SUPPORTED_EXTENSIONS

    fun extensionFromPath(path: String): String =
        File(path).extension.lowercase()

    fun isSupportedPath(path: String): Boolean {
        val ext = extensionFromPath(path)
        return ext.isNotEmpty() && isSupportedExtension(ext)
    }

    /**
     * Reject system paths, other apps' private data, and unsupported extensions.
     */
    fun isSafeReadablePath(path: String, packageName: String): Boolean {
        if (path.isBlank()) return false
        return try {
            val file = File(path)
            val canonical = file.canonicalPath
            if (BLOCKED_PATH_PREFIXES.any { canonical.startsWith(it) }) return false
            if (canonical.startsWith("/data/") && !canonical.contains("/$packageName/")) {
                return false
            }
            if (!file.exists() || !file.isFile || !file.canRead()) return false
            isSupportedPath(canonical)
        } catch (_: Exception) {
            false
        }
    }

    fun sanitizeFileName(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val cleaned = raw
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1F]"), "_")
            .trim()
            .take(180)
        if (cleaned.isEmpty() || cleaned == "." || cleaned == "..") return null
        val ext = cleaned.substringAfterLast('.', "").lowercase()
        return if (ext.isNotEmpty() && isSupportedExtension(ext)) cleaned else null
    }
}
