import 'package:flutter/material.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/sheet_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'professional_sheet_viewer.dart';
import 'modern_pdf_viewer.dart';
import 'text_document_viewer.dart';
import 'image_viewer.dart';

/// Returns embedded viewer content only.
/// The owning screen provides the outer Scaffold/AppBar.
class DocumentViewerFactory {
  static Widget createViewer({
    required ParsedDocumentEntity document,
    required String filePath,
    String? fileName,
    bool invertColors = false,
    bool textMode = false,
    VoidCallback? onInvertToggle,
    VoidCallback? onTextModeToggle,
    VoidCallback? onTap,
    Function(int currentPage, int totalPages)? onPageChanged,
    void Function(String? cellRef, String value)? onSheetSelectionChanged,
    Key? sheetViewerKey,
    double sheetZoom = 1.0,
  }) {
    final format = document.format.toUpperCase();
    final ext = SupportedFormats.extensionOf(filePath) ??
        SupportedFormats.extensionOf(fileName ?? '') ??
        format.toLowerCase();
    final kind = SupportedFormats.viewerKindOf(ext);

    if (kind == ViewerKind.spreadsheet || document.isSpreadsheet) {
      return _buildSpreadsheetViewer(
        document,
        onSheetSelectionChanged,
        sheetViewerKey,
        zoom: sheetZoom,
      );
    }
    if (kind == ViewerKind.pdf || format == 'PDF') {
      return _buildPdfViewer(
        filePath,
        fileName,
        invertColors,
        textMode,
        onInvertToggle,
        onTextModeToggle,
        onTap,
        onPageChanged,
      );
    }
    if (kind == ViewerKind.image || SupportedFormats.isImage(ext)) {
      return _buildImageViewer(filePath, onTap);
    }
    if (kind == ViewerKind.text || format == 'TXT') {
      return _buildTextViewer(document, onTap: onTap);
    }
    return _buildUnsupportedViewer(document.format);
  }

  static Widget _buildSpreadsheetViewer(ParsedDocumentEntity document,
      void Function(String?, String)? onSelectionChanged, Key? sheetViewerKey,
      {double zoom = 1.0}) {
    if (document.sheets.isEmpty) {
      return Center(
        child: Builder(
            builder: (ctx) => Text(
                AppLocalizations.of(ctx)!.documentNoSheets(document.format))),
      );
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: document.sheetCount == 1
          ? _buildSheetTable(
              document.sheets.first,
              onSelectionChanged,
              sheetViewerKey,
              zoom: zoom,
            )
          : DefaultTabController(
              length: document.sheetCount,
              child: Column(
                children: [
                  TabBar(
                    isScrollable: true,
                    tabs: document.sheets
                        .map((sheet) => Tab(text: sheet.name))
                        .toList(),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        for (var i = 0; i < document.sheets.length; i++)
                          _buildSheetTable(
                            document.sheets[i],
                            onSelectionChanged,
                            // GlobalKey must be unique among mounted widgets.
                            // Only the first sheet keeps it for search jump;
                            // other sheets use a ValueKey.
                            i == 0
                                ? sheetViewerKey
                                : ValueKey('sheet_${i}_${document.sheets[i].name}'),
                            zoom: zoom,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  static Widget _buildSheetTable(SheetEntity sheet,
      void Function(String?, String)? onSelectionChanged, Key? sheetViewerKey,
      {double zoom = 1.0}) {
    if (sheet.rows.isEmpty) {
      return Center(
        child: Builder(
            builder: (ctx) =>
                Text(AppLocalizations.of(ctx)!.sheetNoData(sheet.name))),
      );
    }

    return ProfessionalSheetViewer(
      key: sheetViewerKey,
      sheet: sheet,
      onSelectionChanged: onSelectionChanged,
      initialZoom: zoom,
    );
  }

  static Widget _buildPdfViewer(
    String filePath,
    String? fileName,
    bool invertColors,
    bool textMode,
    VoidCallback? onInvertToggle,
    VoidCallback? onTextModeToggle,
    VoidCallback? onTap,
    Function(int currentPage, int totalPages)? onPageChanged,
  ) {
    return ModernPdfViewer(
      filePath: filePath,
      fileName: fileName,
      invertColors: invertColors,
      textMode: textMode,
      onInvertToggle: onInvertToggle,
      onTextModeToggle: onTextModeToggle,
      onTap: onTap,
      onPageChanged: onPageChanged,
    );
  }

  static Widget _buildTextViewer(
    ParsedDocumentEntity document, {
    VoidCallback? onTap,
  }) {
    final textContent = document.searchableText;

    return GestureDetector(
      onTap: onTap,
      child: TextDocumentViewer(
        textContent: textContent,
        onTap: onTap,
      ),
    );
  }

  static Widget _buildImageViewer(String filePath, VoidCallback? onTap) {
    return ImageViewer(
      filePath: filePath,
      onTap: onTap,
    );
  }

  static Widget _buildUnsupportedViewer(String format) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          Text(
            'Format not supported: $format',
            style: const TextStyle(fontSize: 16),
          ),
        ],
      ),
    );
  }
}
