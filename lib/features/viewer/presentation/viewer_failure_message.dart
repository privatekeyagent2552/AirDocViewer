import 'package:air_docs_viewer/features/viewer/domain/viewer_open_failure.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// One plain sentence for a file that could not be shown.
/// [raw] may be a code, a platform message, or an exception string.
/// The returned text is always localized and never a stack trace.
String viewerFailureMessage(AppLocalizations l10n, String? raw) {
  if (ViewerOpenFailure.isTooLarge(raw ?? '')) {
    return l10n.viewerFileTooLarge;
  }
  return l10n.viewerFileOpenFailed;
}
