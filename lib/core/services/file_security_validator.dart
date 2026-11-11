import 'dart:io';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';

final _log = Logger();

/// Result of app-side file security validation (extension + magic bytes).
class FileValidationResult {
  const FileValidationResult.ok()
      : isValid = true,
        reason = null;

  const FileValidationResult.rejected(this.reason) : isValid = false;

  final bool isValid;
  final String? reason;
}

/// Mitigates unrestricted / spoofed file import (VAPT):
/// - allowlist of document/media extensions only
/// - reject executable / script magic signatures (MZ, ELF, shebang, …)
/// - verify common format magic bytes match the claimed extension
class FileSecurityValidator {
  FileSecurityValidator._();

  /// Hard cap for a single imported file (availability / zip-bomb mitigation).
  static const int maxImportBytes = 200 * 1024 * 1024; // 200 MB

  static const int _headerLen = 64;

  /// Executable / malware-related signatures — always rejected.
  static final List<List<int>> _blockedMagics = [
    [0x4D, 0x5A], // MZ — PE / EXE / DLL / SCR
    [0x7F, 0x45, 0x4C, 0x46], // ELF
    [0xCA, 0xFE, 0xBA, 0xBE], // Mach-O fat / Java class
    [0xCE, 0xFA, 0xED, 0xFE], // Mach-O 32
    [0xCF, 0xFA, 0xED, 0xFE], // Mach-O 64
    [0xFE, 0xED, 0xFA, 0xCE],
    [0xFE, 0xED, 0xFA, 0xCF],
    [0x23, 0x21], // #! shebang scripts
  ];

  /// Extensions that are never accepted (defense in depth / malware-adjacent).
  /// Anything outside [SupportedFormats] is also rejected; this list is explicit.
  static const Set<String> blockedExtensions = {
    // Executables / installers
    'exe', 'dll', 'msi', 'msp', 'com', 'scr', 'pif', 'cpl',
    'apk', 'dex', 'so', 'bin', 'run', 'jar', 'war', 'class',
    'app', 'dmg', 'pkg', 'deb', 'rpm', 'ipa',
    'sys', 'drv', 'ocx', 'efi',
    // Scripts / shells / code that can execute
    'bat', 'cmd', 'ps1', 'psm1', 'vbs', 'vbe', 'js', 'jse', 'wsf', 'wsh',
    'sh', 'bash', 'zsh', 'csh', 'ksh',
    'py', 'pyc', 'pyo', 'php', 'rb', 'pl', 'pm', 'lua',
    'java', 'kt', 'kts', 'swift', 'go', 'rs', 'c', 'cpp', 'h', 'hpp',
    'cs', 'vb', 'fs', 'dart', 'ts', 'tsx', 'jsx', 'mjs', 'cjs',
    // Archives / packages (not in allowlist — zip bombs / payload carriers)
    'zip', 'rar', '7z', 'tar', 'gz', 'tgz', 'bz2', 'xz', 'cab', 'iso',
    // Former media / image / open-doc types — no longer accepted
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico', 'tif', 'tiff',
    'heic', 'heif', 'avif', 'psd',
    'mp3', 'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'webm', '3gp', 'm4v',
    'aac', 'wav', 'ogg', 'flac', 'm4a', 'wma', 'opus', 'aiff', 'mpg', 'mpeg',
    'odt', 'ods', 'odp', 'ott', 'rtf', 'epub',
    'html', 'htm', 'md', 'log', 'json', 'xml', 'atom', 'fadrec',
  };

  static String? extensionOf(String pathOrName) =>
      SupportedFormats.extensionOf(pathOrName);

  static Future<FileValidationResult> validateFile(String path,
      {String? claimedName}) async {
    final name = claimedName ?? path;
    final ext = extensionOf(name) ?? extensionOf(path);
    if (ext == null || ext.isEmpty) {
      return const FileValidationResult.rejected('Missing file extension');
    }
    if (blockedExtensions.contains(ext)) {
      return FileValidationResult.rejected(
          'Executable/script type .$ext is not allowed');
    }
    if (!SupportedFormats.isSupported(ext)) {
      return FileValidationResult.rejected(
          'File type .$ext is not an approved document format');
    }

    final file = File(path);
    if (!await file.exists()) {
      return const FileValidationResult.rejected('File not found');
    }
    final length = await file.length();
    if (length <= 0) {
      return const FileValidationResult.rejected('Empty file');
    }
    if (length > maxImportBytes) {
      return FileValidationResult.rejected(
          'File exceeds maximum allowed size (${maxImportBytes ~/ (1024 * 1024)} MB)');
    }

    final raf = await file.open();
    try {
      final toRead = length < _headerLen ? length : _headerLen;
      final header = await raf.read(toRead);
      return validateHeader(Uint8List.fromList(header), ext);
    } finally {
      await raf.close();
    }
  }

  static FileValidationResult validateBytes(
    Uint8List bytes, {
    required String fileName,
  }) {
    final ext = extensionOf(fileName);
    if (ext == null || ext.isEmpty) {
      return const FileValidationResult.rejected('Missing file extension');
    }
    if (blockedExtensions.contains(ext)) {
      return FileValidationResult.rejected(
          'Executable/script type .$ext is not allowed');
    }
    if (!SupportedFormats.isSupported(ext)) {
      return FileValidationResult.rejected(
          'File type .$ext is not an approved document format');
    }
    if (bytes.isEmpty) {
      return const FileValidationResult.rejected('Empty file');
    }
    if (bytes.length > maxImportBytes) {
      return FileValidationResult.rejected(
          'File exceeds maximum allowed size (${maxImportBytes ~/ (1024 * 1024)} MB)');
    }
    final header = bytes.length <= _headerLen
        ? bytes
        : Uint8List.sublistView(bytes, 0, _headerLen);
    return validateHeader(header, ext);
  }

  static FileValidationResult validateHeader(Uint8List header, String ext) {
    if (_matchesAny(header, _blockedMagics)) {
      _log.w('Rejected blocked magic for claimed .$ext');
      return const FileValidationResult.rejected(
          'File content matches an executable or script signature');
    }

    final expected = _expectedMagicFor(ext);
    if (expected == null) {
      // Text-like formats: only require not being binary malware headers.
      if (_looksMostlyBinary(header) && !_isAllowedBinaryTextish(ext)) {
        return const FileValidationResult.rejected(
            'File content does not look like a text/document format');
      }
      return const FileValidationResult.ok();
    }

    if (!_matchesExpected(header, expected)) {
      _log.w('Magic mismatch for .$ext');
      return FileValidationResult.rejected(
          'File content does not match .$ext format (possible type spoofing)');
    }
    return const FileValidationResult.ok();
  }

  /// Sanitize a display name: basename only, strip dangerous chars, require allowlisted ext.
  static String? sanitizeFileName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    var cleaned = raw
        .replaceAll('\\', '/')
        .split('/')
        .last
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .trim();
    if (cleaned.length > 180) cleaned = cleaned.substring(0, 180);
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return null;
    final ext = extensionOf(cleaned);
    if (ext == null ||
        blockedExtensions.contains(ext) ||
        !SupportedFormats.isSupported(ext)) {
      return null;
    }
    return cleaned;
  }

  // ── helpers ─────────────────────────────────────────────────────────

  static bool _startsWith(Uint8List data, List<int> magic) {
    if (data.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[i] != magic[i]) return false;
    }
    return true;
  }

  static bool _matchesAny(Uint8List data, List<List<int>> magics) {
    for (final m in magics) {
      if (_startsWith(data, m)) return true;
    }
    return false;
  }

  /// null => text-like / soft check only (csv, txt).
  static List<_MagicRule>? _expectedMagicFor(String ext) {
    switch (ext) {
      case 'pdf':
        return [_MagicRule.bytes([0x25, 0x50, 0x44, 0x46])]; // %PDF
      case 'docx':
      case 'xlsx':
      case 'pptx':
        return [
          _MagicRule.bytes([0x50, 0x4B, 0x03, 0x04]), // ZIP local
          _MagicRule.bytes([0x50, 0x4B, 0x05, 0x06]), // empty ZIP
          _MagicRule.bytes([0x50, 0x4B, 0x07, 0x08]),
        ];
      case 'doc':
      case 'xls':
      case 'ppt':
        return [
          _MagicRule.bytes([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        ];
      default:
        // csv / txt — reject binary malware headers only
        return null;
    }
  }

  static bool _matchesExpected(Uint8List header, List<_MagicRule> rules) {
    for (final rule in rules) {
      if (rule.matches(header)) return true;
    }
    return false;
  }

  static bool _looksMostlyBinary(Uint8List header) {
    if (header.isEmpty) return true;
    var weird = 0;
    final n = header.length < 32 ? header.length : 32;
    for (var i = 0; i < n; i++) {
      final b = header[i];
      if (b == 0 || (b < 9) || (b > 13 && b < 32)) weird++;
    }
    return weird > n ~/ 4;
  }

  static bool _isAllowedBinaryTextish(String ext) =>
      ext == 'pdf' ||
      ext == 'doc' ||
      ext == 'docx' ||
      ext == 'xls' ||
      ext == 'xlsx' ||
      ext == 'ppt' ||
      ext == 'pptx';
}

class _MagicRule {
  _MagicRule._(this._matcher);

  final bool Function(Uint8List) _matcher;

  bool matches(Uint8List data) => _matcher(data);

  factory _MagicRule.bytes(List<int> magic) => _MagicRule._((data) {
        if (data.length < magic.length) return false;
        for (var i = 0; i < magic.length; i++) {
          if (data[i] != magic[i]) return false;
        }
        return true;
      });
}
