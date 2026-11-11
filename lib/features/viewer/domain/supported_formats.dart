/// Canonical registry of every format Air Docs Viewer can open.
///
/// VAPT: strict allowlist only — PDF + core Office + CSV + TXT.
/// Import, Browse scan, intent filters, DocumentViewerNotifier routing, and
/// ViewerScreen selection MUST all derive from this file so the app never
/// advertises an extension it cannot view.
enum ViewerKind {
  /// PDF engine (pdfrx / ModernPdfViewer).
  pdf,

  /// DOCX / PPTX offline WebView JS visual renderer (with structured fallback).
  richWeb,

  /// Native / Dart structured blocks (DOC, PPT, …).
  structured,

  /// Spreadsheet table viewer.
  spreadsheet,

  /// Plain text viewer.
  text,

  /// Image viewer (unused — images not in allowlist).
  image,

  /// Audio / video media player (unused — media not in allowlist).
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

  /// Browse / Home category key: pdf, documents, spreadsheets, presentations.
  final String category;

  String get formatLabel => extension.toUpperCase();
}

/// Single source of truth for supported file extensions (strict allowlist).
abstract final class SupportedFormats {
  SupportedFormats._();

  /// Only these extensions may be imported, picked, viewed, or opened via intent.
  static const Set<String> allowlist = {
    'pdf',
    'doc',
    'docx',
    'ppt',
    'pptx',
    'xls',
    'xlsx',
    'csv',
    'txt',
  };

  static const pdf = FormatSpec(
    extension: 'pdf',
    viewerKind: ViewerKind.pdf,
    openStrategy: OpenStrategy.direct,
    category: 'pdf',
  );

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
  static const txt = FormatSpec(
    extension: 'txt',
    viewerKind: ViewerKind.text,
    openStrategy: OpenStrategy.parserFirst,
    category: 'documents',
  );

  static const pptx = FormatSpec(
    extension: 'pptx',
    viewerKind: ViewerKind.richWeb,
    openStrategy: OpenStrategy.visualWithFallback,
    category: 'presentations',
  );
  static const ppt = FormatSpec(
    extension: 'ppt',
    // Try visual path first; OLE binary .ppt cannot use the PPTX JS engine and
    // falls back to slide-card text UI (colors/charts need .pptx).
    viewerKind: ViewerKind.richWeb,
    openStrategy: OpenStrategy.visualWithFallback,
    category: 'presentations',
  );

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

  static final Map<String, FormatSpec> _byExt = {
    pdf.extension: pdf,
    docx.extension: docx,
    doc.extension: doc,
    txt.extension: txt,
    pptx.extension: pptx,
    ppt.extension: ppt,
    xlsx.extension: xlsx,
    xls.extension: xls,
    csv.extension: csv,
  };

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

  static bool isAudio(String extension) => false;

  static bool isVideo(String extension) => false;

  static bool isMedia(String extension) => false;

  static bool isImage(String extension) => false;

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
