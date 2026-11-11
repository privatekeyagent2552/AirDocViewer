package com.airdocsviewer

import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

/**
 * Central validation for external file access (intents, imports, parsers).
 *
 * VAPT mitigation: allowlist document/media types only; reject executables
 * and scripts; verify magic-byte signatures to prevent extension spoofing.
 */
object SecurityUtils {
    private const val TAG = "AirDocsViewer.Security"
    private const val MAX_IMPORT_BYTES = 200L * 1024L * 1024L // 200 MB
    private const val HEADER_LEN = 64

    /** Approved document extensions only (strict VAPT allowlist). */
    private val SUPPORTED_EXTENSIONS = setOf(
        "pdf",
        "doc", "docx",
        "ppt", "pptx",
        "xls", "xlsx", "csv",
        "txt",
    )

    /** Never accepted — executables / scripts / media / non-allowlisted types. */
    private val BLOCKED_EXTENSIONS = setOf(
        "exe", "dll", "msi", "msp", "com", "scr", "pif", "cpl",
        "bat", "cmd", "ps1", "psm1", "vbs", "vbe", "js", "jse", "wsf", "wsh",
        "sh", "bash", "zsh", "csh", "ksh",
        "apk", "dex", "so", "bin", "run", "jar", "war", "class",
        "app", "dmg", "pkg", "deb", "rpm", "ipa",
        "sys", "drv", "ocx", "efi",
        "java", "py", "php", "rb", "pl", "lua", "kt", "dart", "ts", "tsx", "jsx",
        "zip", "rar", "7z", "tar", "gz",
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "svg", "ico", "psd",
        "mp3", "mp4", "avi", "mkv", "mov", "wmv", "webm",
        "odt", "ods", "odp", "ott", "rtf", "epub",
        "html", "htm", "md", "log", "json", "xml", "atom", "fadrec",
    )

    private val BLOCKED_PATH_PREFIXES = listOf(
        "/system/",
        "/proc/",
        "/sys/",
        "/dev/",
    )

    fun isSupportedExtension(ext: String): Boolean {
        val e = ext.lowercase()
        if (e in BLOCKED_EXTENSIONS) return false
        return e in SUPPORTED_EXTENSIONS
    }

    fun extensionFromPath(path: String): String =
        File(path).extension.lowercase()

    fun isSupportedPath(path: String): Boolean {
        val ext = extensionFromPath(path)
        return ext.isNotEmpty() && isSupportedExtension(ext)
    }

    /**
     * Reject system paths, other apps' private data, unsupported extensions,
     * and files whose magic bytes do not match (or are executables).
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
            if (!isSupportedPath(canonical)) return false
            validateFileContent(file).also { ok ->
                if (!ok) Log.w(TAG, "Content validation failed for path")
            }
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

    fun validateFileContent(file: File): Boolean {
        if (!file.exists() || !file.isFile) return false
        val length = file.length()
        if (length <= 0L) return false
        if (length > MAX_IMPORT_BYTES) {
            Log.w(TAG, "Rejected oversized file: $length bytes")
            return false
        }
        val ext = file.extension.lowercase()
        if (!isSupportedExtension(ext)) return false
        FileInputStream(file).use { input ->
            return validateStreamHeader(input, ext)
        }
    }

    fun validateStreamHeader(input: InputStream, ext: String): Boolean {
        val header = ByteArray(HEADER_LEN)
        val read = input.read(header)
        if (read <= 0) return false
        val slice = header.copyOf(read)
        if (matchesBlockedMagic(slice)) {
            Log.w(TAG, "Rejected blocked magic for .$ext")
            return false
        }
        return matchesExpectedMagic(slice, ext.lowercase())
    }

    private fun startsWith(data: ByteArray, magic: IntArray): Boolean {
        if (data.size < magic.size) return false
        for (i in magic.indices) {
            if ((data[i].toInt() and 0xFF) != magic[i]) return false
        }
        return true
    }

    private fun matchesBlockedMagic(data: ByteArray): Boolean {
        val blocked = listOf(
            intArrayOf(0x4D, 0x5A), // MZ EXE
            intArrayOf(0x7F, 0x45, 0x4C, 0x46), // ELF
            intArrayOf(0xCA, 0xFE, 0xBA, 0xBE),
            intArrayOf(0xCE, 0xFA, 0xED, 0xFE),
            intArrayOf(0xCF, 0xFA, 0xED, 0xFE),
            intArrayOf(0xFE, 0xED, 0xFA, 0xCE),
            intArrayOf(0xFE, 0xED, 0xFA, 0xCF),
            intArrayOf(0x23, 0x21), // #!
        )
        return blocked.any { startsWith(data, it) }
    }

    private fun matchesExpectedMagic(data: ByteArray, ext: String): Boolean {
        return when (ext) {
            "pdf" -> startsWith(data, intArrayOf(0x25, 0x50, 0x44, 0x46))
            "docx", "xlsx", "pptx" ->
                startsWith(data, intArrayOf(0x50, 0x4B, 0x03, 0x04)) ||
                    startsWith(data, intArrayOf(0x50, 0x4B, 0x05, 0x06)) ||
                    startsWith(data, intArrayOf(0x50, 0x4B, 0x07, 0x08))
            "doc", "xls", "ppt" ->
                startsWith(
                    data,
                    intArrayOf(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1),
                )
            // Soft formats: blocked-magic gate already applied above.
            "txt", "csv" -> true
            else -> false
        }
    }
}
