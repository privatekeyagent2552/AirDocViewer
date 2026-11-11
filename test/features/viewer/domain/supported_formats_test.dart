import 'package:flutter_test/flutter_test.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';

void main() {
  group('SupportedFormats registry (strict allowlist)', () {
    const expected = {
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

    test('allowlist is exactly the nine approved document types', () {
      expect(SupportedFormats.allExtensions.toSet(), expected);
      expect(SupportedFormats.allowlist, expected);
    });

    test('every advertised extension maps to a concrete viewer kind', () {
      for (final ext in SupportedFormats.allExtensions) {
        final spec = SupportedFormats.of(ext);
        expect(spec, isNotNull, reason: '.$ext missing FormatSpec');
        expect(spec!.viewerKind, isNotNull);
        expect(spec.openStrategy, isNotNull);
        expect(spec.category, isNotEmpty);
      }
    });

    test('core office formats use expected strategies', () {
      expect(SupportedFormats.of('pdf')!.openStrategy, OpenStrategy.direct);
      expect(
          SupportedFormats.of('docx')!.openStrategy,
          OpenStrategy.visualWithFallback);
      expect(
          SupportedFormats.of('pptx')!.openStrategy,
          OpenStrategy.visualWithFallback);
      expect(SupportedFormats.of('docx')!.viewerKind, ViewerKind.richWeb);
      expect(SupportedFormats.of('pptx')!.viewerKind, ViewerKind.richWeb);
      expect(SupportedFormats.of('ppt')!.openStrategy, OpenStrategy.visualWithFallback);
      expect(SupportedFormats.of('ppt')!.viewerKind, ViewerKind.richWeb);
      expect(SupportedFormats.of('doc')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('doc')!.viewerKind, ViewerKind.structured);
      expect(SupportedFormats.of('xlsx')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('csv')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('txt')!.viewerKind, ViewerKind.text);
    });

    test('picker extensions equal registry extensions', () {
      expect(
        SupportedFormats.pickerExtensions.toSet(),
        SupportedFormats.allExtensions.toSet(),
      );
    });

    test('unsupported and former media/code types are rejected', () {
      expect(SupportedFormats.of('xyzzy'), isNull);
      expect(SupportedFormats.isSupported(''), isFalse);
      expect(SupportedFormats.isSupported(null), isFalse);
      for (final ext in [
        'exe', 'bat', 'js', 'apk', 'png', 'mp4', 'mp3', 'html', 'json',
        'odt', 'rtf', 'epub', 'zip', 'py', 'java',
      ]) {
        expect(SupportedFormats.isSupported(ext), isFalse, reason: '.$ext');
      }
    });

    test('extensionOf handles windows and posix paths', () {
      expect(SupportedFormats.extensionOf(r'C:\docs\file.PPTX'), 'pptx');
      expect(SupportedFormats.extensionOf('/sdcard/a.Docx'), 'docx');
      expect(SupportedFormats.extensionOf('noext'), isNull);
    });

    test('images and media helpers are disabled', () {
      expect(SupportedFormats.isImage('png'), isFalse);
      expect(SupportedFormats.isMedia('mp4'), isFalse);
      expect(SupportedFormats.isAudio('mp3'), isFalse);
      expect(SupportedFormats.isVideo('mp4'), isFalse);
    });
  });
}
