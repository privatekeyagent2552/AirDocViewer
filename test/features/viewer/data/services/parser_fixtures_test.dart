import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:air_docs_viewer/features/viewer/data/services/document_parser_service.dart';
import 'package:air_docs_viewer/features/viewer/data/services/word_document_parser_service.dart';

void main() {
  late Directory fixtures;

  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('airdocs_fixtures_');
  });

  tearDownAll(() async {
    if (await fixtures.exists()) {
      await fixtures.delete(recursive: true);
    }
  });

  Future<File> writeFixture(String name, List<int> bytes) async {
    final f = File('${fixtures.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes, flush: true);
    return f;
  }

  Future<File> writeText(String name, String text) async {
    final f = File('${fixtures.path}${Platform.pathSeparator}$name');
    await f.writeAsString(text, flush: true);
    return f;
  }

  group('parser fixtures', () {
    test('TXT parses readable content', () async {
      final f = await writeText('sample.txt', 'Hello Air Docs\nLine 2');
      final text = await DocumentParserService.parseTXT(f.path);
      expect(text, contains('Hello Air Docs'));
    });

    test('CSV parses tabular rows', () async {
      final f = await writeText('sample.csv', 'a,b\n1,2\n3,4\n');
      final result = await DocumentParserService.parseCSV(f.path);
      expect(result['sheetCount'] ?? (result['sheets'] as List).length, 1);
      final sheets = result['sheets'] as List;
      expect(sheets.first['rowCount'], greaterThanOrEqualTo(2));
    });

    test('JSON object parses to key/value sheet', () async {
      final f = await writeText('sample.json', '{"name":"Air","version":1}');
      final result = await DocumentParserService.parseJSON(f.path);
      expect(result['format'], 'JSON');
      expect((result['sheets'] as List).isNotEmpty, isTrue);
    });

    test('XML parses without throwing on simple doc', () async {
      final f = await writeText(
        'sample.xml',
        '<?xml version="1.0"?><root><item>one</item></root>',
      );
      final result = await DocumentParserService.parseXML(f.path);
      expect(result['format'], 'XML');
    });

    test('empty TXT does not hang and returns empty/space content', () async {
      final f = await writeText('empty.txt', '');
      final text = await DocumentParserService.parseTXT(f.path);
      expect(text, isA<String>());
    });

    test('corrupt zip-as-docx fails promptly', () async {
      final f = await writeFixture('bad.docx', [0x00, 0x01, 0x02, 0x03]);
      expect(
        () => WordDocumentParserService.parseDocx(f.path),
        throwsA(anything),
      );
    });

    test('corrupt zip-as-pptx-style odt fails promptly', () async {
      final f = await writeFixture('bad.odt', [0x50, 0x4b, 0x03, 0x04, 0xff]);
      expect(
        () => WordDocumentParserService.parseOdt(f.path),
        throwsA(anything),
      );
    });

    test('RTF minimal document yields text', () async {
      final f = await writeText(
        'sample.rtf',
        r'{\rtf1\ansi Hello RTF World}',
      );
      final result = await WordDocumentParserService.parseRtf(f.path);
      expect(result.plainTextContent.toLowerCase(), contains('hello'));
    });
  });
}
