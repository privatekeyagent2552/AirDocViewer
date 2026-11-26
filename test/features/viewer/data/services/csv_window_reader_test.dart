import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:air_docs_viewer/features/viewer/data/services/csv_window_reader.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('air_docs_csv_window');
  });

  tearDown(() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  });

  Future<File> write(String name, String text) async {
    final file = File('${directory.path}/$name');
    await file.writeAsString(text);
    return file;
  }

  test('small file is the whole sheet, including quoted commas', () async {
    final file = await write(
      'small.csv',
      'name,notes\n'
          '"Doe, Jane","Line 1\nLine 2"\n'
          '"Quote","He said ""hello"""',
    );

    final window = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      rowCount: 10,
      colCount: 10,
    );

    expect(window.rows, [
      ['name', 'notes'],
      ['Doe, Jane', 'Line 1\nLine 2'],
      ['Quote', 'He said "hello"'],
    ]);
    expect(window.hasMoreRows, isFalse);
    expect(window.hasMoreCols, isFalse);
  });

  test('next window starts on a record boundary, not inside quotes', () async {
    final file = await write(
      'quoted.csv',
      'a,"line1\nline2",b\n'
          '"d,e",f\n',
    );
    final first = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      rowCount: 1,
      colCount: 5,
    );
    expect(first.rows, [
      ['a', 'line1\nline2', 'b'],
    ]);
    expect(first.hasMoreRows, isTrue);

    final second = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: first.endByte,
      startRow: 1,
      rowCount: 1,
      colCount: 5,
    );
    expect(second.rows, [
      ['d,e', 'f'],
    ]);
    expect(second.startByte, first.endByte);
    expect(second.hasMoreRows, isFalse);
  });

  test('cell cap keeps later rows and columns', () async {
    final file = await write(
      'wide.csv',
      '"${'x' * (70 * 1024)}\nstill,more",z\n'
          'next,ok\n',
    );
    final window = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      rowCount: 10,
      colCount: 5,
    );
    expect(window.rows, hasLength(2));
    expect(window.rows[0][0].length, CsvWindowReader.maxCellChars);
    expect(window.rows[0][0], 'x' * CsvWindowReader.maxCellChars);
    expect(window.rows[0][1], 'z');
    expect(window.rows[1], ['next', 'ok']);
  });

  test('column window does not drop the other rows', () async {
    final file = await write(
      'cols.csv',
      'a,b,c,d\n'
          '1,2,3,4\n',
    );
    final window = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      startCol: 2,
      rowCount: 10,
      colCount: 1,
    );
    expect(window.rows, [
      ['c'],
      ['3'],
    ]);
    expect(window.hasMoreCols, isTrue);
  });

  test('row windows cover every record and stop at the last one', () async {
    final buf = StringBuffer();
    for (var i = 0; i < 450; i++) {
      buf.write('r$i,c$i\n');
    }
    final file = await write('long.csv', buf.toString());
    final length = await file.length();

    final first = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      rowCount: 200,
      colCount: 2,
    );
    expect(first.rows, hasLength(200));
    expect(first.rows.first, ['r0', 'c0']);
    expect(first.rows.last, ['r199', 'c199']);
    expect(first.hasMoreRows, isTrue);
    expect(first.endByte, lessThan(length));

    final second = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: first.endByte,
      startRow: 200,
      rowCount: 200,
      colCount: 2,
    );
    expect(second.rows.first, ['r200', 'c200']);
    expect(second.rows, hasLength(200));

    final third = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: second.endByte,
      startRow: 400,
      rowCount: 200,
      colCount: 2,
    );
    expect(third.rows, hasLength(50));
    expect(third.rows.first, ['r400', 'c400']);
    expect(third.rows.last, ['r449', 'c449']);
    expect(third.hasMoreRows, isFalse);

    final past = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: third.endByte,
      startRow: 600,
      rowCount: 200,
      colCount: 2,
    );
    expect(past.rows, isEmpty);
    expect(past.hasMoreRows, isFalse);
  });

  test('bom, crlf, and a trailing newline do not add a phantom row', () async {
    final file = File('${directory.path}/bom.csv');
    await file.writeAsBytes([
      0xEF,
      0xBB,
      0xBF,
      ...('a,b\r\nc,d\r\n').codeUnits,
    ]);
    final window = await CsvWindowReader.read(
      filePath: file.path,
      byteOffset: 0,
      startRow: 0,
      rowCount: 10,
      colCount: 4,
    );
    expect(window.rows, [
      ['a', 'b'],
      ['c', 'd'],
    ]);
    expect(window.startByte, 3);
  });
}
