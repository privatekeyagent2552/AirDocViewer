/// Canonical registry of every format Air Docs Viewer can open.
///
/// Import, Browse scan, intent filters, DocumentViewerNotifier routing, and
/// ViewerScreen selection MUST all derive from this file so the app never
/// advertises an extension it cannot view.
enum ViewerKind {
  /// PDF engine (pdfrx / ModernPdfViewer).
  pdf,

  /// DOCX / PPTX offline WebView JS visual renderer (with structured fallback).
  richWeb,

  /// Native / Dart structured blocks (DOC, RTF, ODT, PPT, EPUB, …).
  structured,

  /// Spreadsheet table viewer.
  spreadsheet,

  /// Plain / code text viewer.
  text,

  /// Image viewer.
  image,

  /// Audio / video media player.
  media,
}

enum OpenStrategy {
  /// Show viewer immediately with a stub entity (file bytes are enough).
  direct,

  /// Must parse before the first frame of content.
  parserFirst,

  /// Show visual viewer now; if it fails, parse to structured/text fallback.
  visualWithFallback,
}

class FormatSpec {
  const FormatSpec({
    required this.extension,
    required this.viewerKind,
    required this.openStrategy,
    required this.category,
  });

  final String extension;
  final ViewerKind viewerKind;
  final OpenStrategy openStrategy;

  /// Browse / Home category key: pdf, documents, spreadsheets, presentations,
  /// images, media, code, other.
  final String category;

  String get formatLabel => extension.toUpperCase();
}

/// Single source of truth for supported file extensions.
abstract final class SupportedFormats {
  SupportedFormats._();

  static const pdf = FormatSpec(
    extension: 'pdf',
    viewerKind: ViewerKind.pdf,
    openStrategy: OpenStrategy.direct,
    category: 'pdf',
  );

  // ── Word / text docs ────────────────────────────────────────────────
  static const docx = FormatSpec(
    extension: 'docx',
    viewerKind: ViewerKind.richWeb,
    openStrategy: OpenStrategy.visualWithFallback,
    category: 'documents',
  );
  static const doc = FormatSpec(
    extension: 'doc',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );
  static const odt = FormatSpec(
    extension: 'odt',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );
  static const ott = FormatSpec(
    extension: 'ott',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );
  static const rtf = FormatSpec(
    extension: 'rtf',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );
  static const epub = FormatSpec(
    extension: 'epub',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );

  // ── Presentations ───────────────────────────────────────────────────
  static const pptx = FormatSpec(
    extension: 'pptx',
    viewerKind: ViewerKind.richWeb,
    openStrategy: OpenStrategy.visualWithFallback,
    category: 'presentations',
  );
  static const ppt = FormatSpec(
    extension: 'ppt',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'presentations',
  );
  static const odp = FormatSpec(
    extension: 'odp',
    viewerKind: ViewerKind.structured,
    openStrategy: OpenStrategy.parserFirst,
    category: 'presentations',
  );

  // ── Spreadsheets ────────────────────────────────────────────────────
  static const xlsx = FormatSpec(
    extension: 'xlsx',
    viewerKind: ViewerKind.spreadsheet,
    openStrategy: OpenStrategy.parserFirst,
    category: 'spreadsheets',
  );
  static const xls = FormatSpec(
    extension: 'xls',
    viewerKind: ViewerKind.spreadsheet,
    openStrategy: OpenStrategy.parserFirst,
    category: 'spreadsheets',
  );
  static const csv = FormatSpec(
    extension: 'csv',
    viewerKind: ViewerKind.spreadsheet,
    openStrategy: OpenStrategy.parserFirst,
    category: 'spreadsheets',
  );
  static const ods = FormatSpec(
    extension: 'ods',
    viewerKind: ViewerKind.spreadsheet,
    openStrategy: OpenStrategy.parserFirst,
    category: 'spreadsheets',
  );

  // ── Images Flutter Image.file can show ──────────────────────────────
  static const _imageExts = {
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'ico',
  };

  // Extra image / raster types we advertise but may only show via file
  // decode attempt (error UI if decode fails).
  static const _extraImageExts = {
    'tif', 'tiff', 'heic', 'heif', 'avif', 'psd',
  };

  // ── Audio / video ───────────────────────────────────────────────────
  static const _audioExts = {
    'aac', 'mp3', 'wav', 'ogg', 'flac', 'm4a', 'wma', 'opus', 'aiff',
  };
  static const _videoExts = {
    'mp4', 'avi', 'mkv', 'mov', 'wmv', 'flv', 'webm', '3gp', 'm4v',
    'mpg', 'mpeg', 'fmp4',
  };

  // ── Plain / code / config text ──────────────────────────────────────
  static const _textExts = {
    'txt', 'md', 'log', 'html', 'htm',
    'java', 'py', 'sh', 'bash',
    'dart', 'kt', 'kts', 'js', 'ts', 'jsx', 'tsx',
    'c', 'cpp', 'h', 'hpp', 'cs', 'php', 'rb', 'swift', 'go', 'rs',
    'sql', 'yaml', 'yml', 'toml', 'gradle', 'properties', 'ini', 'conf',
    'bat', 'cmd', 'ps1', 'r',
    'atom',
  };

  // ── Structured data viewed as text / light table ────────────────────
  static const json = FormatSpec(
    extension: 'json',
    viewerKind: ViewerKind.text,
    openStrategy: OpenStrategy.parserFirst,
    category: 'code',
  );
  static const xml = FormatSpec(
    extension: 'xml',
    viewerKind: ViewerKind.text,
    openStrategy: OpenStrategy.parserFirst,
    category: 'code',
  );
  static const fadrec = FormatSpec(
    extension: 'fadrec',
    viewerKind: ViewerKind.text,
    openStrategy: OpenStrategy.parserFirst,
    category: 'code',
  );

  static final Map<String, FormatSpec> _byExt = () {
    final map = <String, FormatSpec>{
      pdf.extension: pdf,
      docx.extension: docx,
      doc.extension: doc,
      odt.extension: odt,
      ott.extension: ott,
      rtf.extension: rtf,
      epub.extension: epub,
      pptx.extension: pptx,
      ppt.extension: ppt,
      odp.extension: odp,
      xlsx.extension: xlsx,
      xls.extension: xls,
      csv.extension: csv,
      ods.extension: ods,
      json.extension: json,
      xml.extension: xml,
      fadrec.extension: fadrec,
    };

    for (final e in _imageExts) {
      map[e] = FormatSpec(
        extension: e,
        viewerKind: ViewerKind.image,
        openStrategy: OpenStrategy.direct,
        category: 'images',
      );
    }
    for (final e in _extraImageExts) {
      map[e] = FormatSpec(
        extension: e,
        viewerKind: ViewerKind.image,
        openStrategy: OpenStrategy.direct,
        category: 'images',
      );
    }
    for (final e in _audioExts) {
      map[e] = FormatSpec(
        extension: e,
        viewerKind: ViewerKind.media,
        openStrategy: OpenStrategy.direct,
        category: 'audio',
      );
    }
    for (final e in _videoExts) {
      map[e] = FormatSpec(
        extension: e,
        viewerKind: ViewerKind.media,
        openStrategy: OpenStrategy.direct,
        category: 'video',
      );
    }
    for (final e in _textExts) {
      map[e] = FormatSpec(
        extension: e,
        viewerKind: ViewerKind.text,
        openStrategy: OpenStrategy.parserFirst,
        category: 'code',
      );
    }
    // Plain TXT is documents category, not code.
    map['txt'] = const FormatSpec(
      extension: 'txt',
      viewerKind: ViewerKind.text,
      openStrategy: OpenStrategy.parserFirst,
      category: 'documents',
    );
    return map;
  }();

  /// Every supported extension (lowercase, no dot).
  static List<String> get allExtensions =>
      _byExt.keys.toList(growable: false)..sort();

  /// Extensions suitable for `FilePicker.allowedExtensions`.
  static List<String> get pickerExtensions => allExtensions;

  static bool isSupported(String? extension) {
    if (extension == null || extension.isEmpty) return false;
    return _byExt.containsKey(extension.toLowerCase());
  }

  static FormatSpec? of(String? extension) {
    if (extension == null || extension.isEmpty) return null;
    return _byExt[extension.toLowerCase()];
  }

  static FormatSpec? ofPath(String path, {String? fileName}) {
    return of(extensionOf(path) ?? extensionOf(fileName ?? ''));
  }

  static String? extensionOf(String pathOrName) {
    if (pathOrName.isEmpty) return null;
    final name = pathOrName.split(RegExp(r'[\\/]')).last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    return ext.isEmpty ? null : ext;
  }

  static String categoryOf(String extension) =>
      of(extension)?.category ?? 'other';

  static ViewerKind? viewerKindOf(String extension) => of(extension)?.viewerKind;

  static bool isAudio(String extension) => _audioExts.contains(extension.toLowerCase());

  static bool isVideo(String extension) => _videoExts.contains(extension.toLowerCase());

  static bool isMedia(String extension) =>
      isAudio(extension) || isVideo(extension);

  static bool isImage(String extension) {
    final e = extension.toLowerCase();
    return _imageExts.contains(e) || _extraImageExts.contains(e);
  }

  static bool isSpreadsheet(String extension) {
    final kind = of(extension)?.viewerKind;
    return kind == ViewerKind.spreadsheet;
  }

  static bool isRichWeb(String extension) {
    final kind = of(extension)?.viewerKind;
    return kind == ViewerKind.richWeb;
  }

  static bool isDirectOpen(String extension) {
    final s = of(extension)?.openStrategy;
    return s == OpenStrategy.direct || s == OpenStrategy.visualWithFallback;
  }
}
