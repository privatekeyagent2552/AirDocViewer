import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';

/// Stable codes stored on [ParsedDocumentState.error].
/// The viewer maps these to localized sentences and never shows the raw text.
abstract final class ViewerOpenFailure {
  static const tooLargeCode = 'FILE_TOO_LARGE';
  static const openFailedCode = 'FILE_OPEN_FAILED';

  static String codeFor(Object error) {
    final raw = error.toString();
    if (raw == tooLargeCode || raw == openFailedCode) return raw;
    if (isTooLarge(raw)) return tooLargeCode;
    return openFailedCode;
  }

  /// A parse that returned no rows, slides, or text because it ran out of
  /// memory or was cut off. A real empty sheet has no failure warning.
  static String? codeForDocument(ParsedDocumentEntity document) {
    if (document.parseWarnings.isEmpty) return null;
    final joined = document.parseWarnings.join('\n');
    if (!_signalsFailure(joined)) return null;
    if (_hasReadablePayload(document)) return null;
    return isTooLarge(joined) ? tooLargeCode : openFailedCode;
  }

  static bool isTooLarge(String raw) {
    final s = raw.toLowerCase();
    return s.contains('file_too_large') ||
        s.contains('too large') ||
        s.contains('too much text') ||
        s.contains('out of memory') ||
        s.contains('outofmemory') ||
        s.contains('ran out of memory') ||
        s.contains('exceeds maximum') ||
        s.contains('maximum allowed size') ||
        s.contains('fits in memory') ||
        s.contains('partial copy');
  }

  static bool _signalsFailure(String raw) {
    final s = raw.toLowerCase();
    return isTooLarge(raw) ||
        s.contains('parse error') ||
        s.contains('parse_error') ||
        s.contains('reflection_error') ||
        s.contains('could not be opened') ||
        s.contains('could not open') ||
        s.contains('unsupported') ||
        s.contains('corrupt') ||
        s.contains('damaged');
  }

  static bool _hasReadablePayload(ParsedDocumentEntity document) {
    if (document.sheets.any((sheet) => sheet.rows.isNotEmpty)) return true;
    if (document.slides.isNotEmpty) return true;
    if ((document.plainTextContent ?? '').trim().isNotEmpty) return true;
    if (document.documentBlocks.isNotEmpty) return true;
    return false;
  }
}
