import 'package:flutter_test/flutter_test.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';

void main() {
  group('SupportedFormats registry', () {
    test('every advertised extension maps to a concrete viewer kind', () {
      final exts = SupportedFormats.allExtensions;
      expect(exts, isNotEmpty);
      for (final ext in exts) {
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
      expect(SupportedFormats.of('ppt')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('ppt')!.viewerKind, ViewerKind.structured);
      expect(SupportedFormats.of('doc')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('doc')!.viewerKind, ViewerKind.structured);
      expect(SupportedFormats.of('xlsx')!.openStrategy, OpenStrategy.parserFirst);
      expect(SupportedFormats.of('csv')!.openStrategy, OpenStrategy.parserFirst);
    });

    test('picker extensions equal registry extensions', () {
      expect(
        SupportedFormats.pickerExtensions.toSet(),
        SupportedFormats.allExtensions.toSet(),
      );
    });

    test('unsupported extension returns null', () {
      expect(SupportedFormats.of('xyzzy'), isNull);
      expect(SupportedFormats.isSupported(''), isFalse);
      expect(SupportedFormats.isSupported(null), isFalse);
    });

    test('extensionOf handles windows and posix paths', () {
      expect(SupportedFormats.extensionOf(r'C:\docs\file.PPTX'), 'pptx');
      expect(SupportedFormats.extensionOf('/sdcard/a.Docx'), 'docx');
      expect(SupportedFormats.extensionOf('noext'), isNull);
    });

    test('fadrec and code formats route to text viewer', () {
      expect(SupportedFormats.of('fadrec')!.viewerKind, ViewerKind.text);
      expect(SupportedFormats.of('dart')!.viewerKind, ViewerKind.text);
      expect(SupportedFormats.of('kt')!.viewerKind, ViewerKind.text);
      expect(SupportedFormats.of('json')!.viewerKind, ViewerKind.text);
    });

    test('images and media are direct-open', () {
      expect(SupportedFormats.of('png')!.openStrategy, OpenStrategy.direct);
      expect(SupportedFormats.of('mp4')!.openStrategy, OpenStrategy.direct);
      expect(SupportedFormats.of('mp3')!.openStrategy, OpenStrategy.direct);
    });
  });
}
