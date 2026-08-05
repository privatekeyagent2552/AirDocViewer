// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/document_viewer_factory.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/text_document_viewer.dart';

void main() {
  testWidgets('text document resolves to a concrete viewer',
      (WidgetTester tester) async {
    final document = ParsedDocumentEntity(
      format: 'TXT',
      sheets: const [],
      plainTextContent: 'Offline document content',
      parsedAt: DateTime(2026),
      sourceFilePath: '/tmp/sample.txt',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DocumentViewerFactory.createViewer(
            document: document,
            filePath: document.sourceFilePath,
          ),
        ),
      ),
    );

    expect(find.byType(TextDocumentViewer), findsOneWidget);
  });
}
