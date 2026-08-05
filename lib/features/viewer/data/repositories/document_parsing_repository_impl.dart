import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/sheet_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/repositories/document_parsing_repository.dart';
import 'package:air_docs_viewer/features/viewer/data/services/cache_service.dart';
import 'package:air_docs_viewer/features/viewer/data/services/document_parser_service.dart';
import 'package:air_docs_viewer/features/viewer/data/services/office_glyph_sanitizer.dart';
import 'package:air_docs_viewer/features/viewer/data/services/platform_channel_service.dart';
import 'package:air_docs_viewer/features/viewer/data/services/word_document_parser_service.dart';

final log = Logger();

/// Production implementation of DocumentParsingRepository
///
/// Orchestrates:
/// - Native parsing via platform channels
/// - Fallback to Dart parsing
/// - Result caching with file modification validation
/// - Multiple file format support
class DocumentParsingRepositoryImpl implements DocumentParsingRepository {
  final PlatformChannelService _platformChannel;
  final CacheService _cache;

  DocumentParsingRepositoryImpl({
    required PlatformChannelService platformChannel,
    required CacheService cache,
  })  : _platformChannel = platformChannel,
        _cache = cache;

  @override
  Future<ParsedDocumentEntity> parseSpreadsheet(String filePath) async {
    final ext = filePath.toLowerCase().split('.').last;

    switch (ext) {
      case 'xlsx':
      case 'xls':
        return parseXLSX(filePath, useNativeParsing: true);
      case 'csv':
        return parseCSV(filePath);
      case 'ods':
        return parseODS(filePath);
      case 'json':
        return parseJSON(filePath);
      case 'fadrec':
        // .fadrec is a custom JSON format from FadCam companion app
        return parseFadrec(filePath);
      case 'xml':
        return parseXML(filePath);
      default:
        throw Exception('Unsupported format: $ext');
    }
  }

  /// Parse JSON file - Pure Dart, lightweight, no native needed
  /// JSON is fast in Dart, no fallback required
  @override
  Future<ParsedDocumentEntity> parseJSON(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached JSON: $filePath');
      return cached;
    }

    try {
      log.i('Parsing JSON (Dart): $filePath');
      final dartResult = await compute(DocumentParserService.parseJSON, filePath);
      final result = _toParsedEntity(dartResult, format: 'JSON');
      log.d('JSON parsed: ${result.textContent?.length} chars');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('JSON parsing failed: $e', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Parse .fadrec format (custom JSON from FadCam companion app)
  /// Treat as JSON with special format identification
  @override
  Future<ParsedDocumentEntity> parseFadrec(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached FADREC: $filePath');
      return cached;
    }

    try {
      log.i('Parsing FADREC (Dart): $filePath');
      final dartResult = await compute(DocumentParserService.parseJSON, filePath);
      final result = _toParsedEntity(dartResult, format: 'FADREC');
      log.d('FADREC parsed as JSON');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('FADREC parsing failed: $e', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Parse XML format
  @override
  Future<ParsedDocumentEntity> parseXML(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached XML: $filePath');
      return cached;
    }

    try {
      log.i('Parsing XML (Dart): $filePath');
      final dartResult = await compute(DocumentParserService.parseXML, filePath);
      final result = _toParsedEntity(dartResult, format: 'XML');
      log.d(
          'XML parsed: valid=${dartResult['isValid']}, elements=${dartResult['elementCount']}');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('XML parsing failed: $e', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Parse ODS (OpenDocument Spreadsheet)
  @override
  Future<ParsedDocumentEntity> parseODS(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached ODS: $filePath');
      return cached;
    }

    try {
      log.i('Parsing ODS (Dart): $filePath');
      final dartResult = await compute(DocumentParserService.parseODS, filePath);
      final result = _toParsedEntity(dartResult, format: 'ODS');
      log.d('ODS parsed: ${result.sheets.length} sheets');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('ODS parsing failed: $e', error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<ParsedDocumentEntity> parseXLSX(
    String filePath, {
    bool useNativeParsing = false,
  }) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached XLSX: $filePath (format: ${cached.format})');
      return cached;
    }

    // Determine format from file extension
    final format = filePath.toLowerCase().endsWith('.xls') ? 'XLS' : 'XLSX';
    log.i('Parsing $format (NATIVE, no fallback): $filePath');

    // XLSX/XLS MUST use native parsing - no fallback
    // These are heavy formats, native is REQUIRED for performance
    try {
      log.d('Calling native parser channel for $format...');
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, format);

      log.d(
          'Native parser returned: sheets=${nativeResult['sheetCount']}, format=${nativeResult['format']}');

      final result = _toParsedEntity(nativeResult, format: format);

      log.i('Successfully parsed $format: ${result.sheets.length} sheets');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('NATIVE PARSING FAILED for $format: $e', error: e, stackTrace: st);
      log.d('Failed file path: $filePath');
      log.d('Native channel may not be available or file may be corrupted');
      rethrow; // Let it fail - this is critical
    }
  }

  @override
  Future<ParsedDocumentEntity> parseCSV(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached CSV: $filePath');
      return cached;
    }

    log.i('Parsing CSV (NATIVE): $filePath');
    try {
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, 'CSV');
      final result = _toParsedEntity(nativeResult, format: 'CSV');
      log.i('Successfully parsed CSV: ${result.sheets.length} sheets');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.w('Native CSV parsing failed, falling back to Dart parser: $e',
          error: e, stackTrace: st);
      final dartResult = await DocumentParserService.parseCSV(filePath);
      final result = _toParsedEntity(dartResult, format: 'CSV');
      await cacheParsing(filePath, result);
      return result;
    }
  }

  @override
  Future<ParsedDocumentEntity> parseDOCX(String filePath) async {
    // Visual DOCX preview is handled by the bundled WebView renderer.
    // Skip slow native/Dart text parse so the viewer can open immediately.
    log.i('DOCX: returning visual stub (WebView renders layout): $filePath');
    return ParsedDocumentEntity(
      format: 'DOCX',
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      fidelityLevel: DocumentFidelityLevel.rich,
    );
  }

  @override
  Future<ParsedDocumentEntity> parseDOCXStructured(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null &&
        cached.format == 'DOCX' &&
        (cached.hasRichDocument || (cached.plainTextContent?.isNotEmpty ?? false))) {
      log.i('Using cached structured DOCX: $filePath');
      return cached;
    }

    log.i('Parsing DOCX structured fallback: $filePath');
    try {
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, 'DOCX');
      final result = _toParsedEntity(nativeResult, format: 'DOCX').copyWith(
        fidelityLevel: (nativeResult['documentBlocks'] as List?)?.isNotEmpty == true
            ? DocumentFidelityLevel.partial
            : DocumentFidelityLevel.plainText,
        parseWarnings: ((nativeResult['parseWarnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      final message = e.toString();
      if (message.contains('OLE2NotOfficeXmlFileException') ||
          message.contains('appears to be in the OLE2 Format')) {
        log.w('File named DOCX contains legacy DOC/OLE2 data; parsing as DOC');
        final legacyResult =
            await _platformChannel.parseDocumentNative(filePath, 'DOC');
        final result =
            _toParsedEntity(legacyResult, format: 'DOCX').copyWith(
          format: 'DOCX',
          fidelityLevel:
              (legacyResult['documentBlocks'] as List?)?.isNotEmpty == true
                  ? DocumentFidelityLevel.partial
                  : DocumentFidelityLevel.plainText,
          parseWarnings: [
            'This file uses legacy DOC data despite its .docx extension.',
            ...((legacyResult['parseWarnings'] as List?) ?? const [])
                .map((item) => item.toString()),
          ],
        );
        await cacheParsing(filePath, result);
        return result;
      }

      log.w('Native DOCX fallback failed, trying Dart parser: $e',
          error: e, stackTrace: st);
      final structured = await WordDocumentParserService.parseDocx(filePath);
      final result = ParsedDocumentEntity(
        format: 'DOCX',
        sheets: const [],
        sheetCount: 0,
        parsedAt: DateTime.now(),
        sourceFilePath: filePath,
        plainTextContent: structured.plainTextContent,
        documentBlocks: structured.documentBlocks,
        parseWarnings: structured.parseWarnings,
        fidelityLevel: structured.fidelityLevel,
        wordCount: _countWords(structured.plainTextContent),
        lineCount: _countLines(structured.plainTextContent),
      );
      await cacheParsing(filePath, result);
      return result;
    }
  }

  @override
  Future<ParsedDocumentEntity> parseDOC(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached DOC: $filePath');
      return cached;
    }

    log.i('Parsing DOC (NATIVE, no fallback): $filePath');

    // DOC MUST use native parsing - Dart binary extraction produces garbage
    try {
      log.d('Calling native parser channel for DOC...');
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, 'DOC');

      log.d(
          'Native parser returned: textContent=${(nativeResult['textContent'] as String?)?.length} chars, format=${nativeResult['format']}');

      final result = _toParsedEntity(nativeResult, format: 'DOC').copyWith(
        fidelityLevel: nativeResult['documentBlocks'] != null
            ? DocumentFidelityLevel.partial
            : DocumentFidelityLevel.plainText,
        parseWarnings: ((nativeResult['parseWarnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

      log.i(
          'Successfully parsed DOC: ${(result.textContent ?? '').length} characters');
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('NATIVE PARSING FAILED for DOC: $e', error: e, stackTrace: st);
      log.d('Failed file path: $filePath');
      log.d('Native channel may not be available or file may be corrupted');
      rethrow; // Let it fail - this is critical
    }
  }

  @override
  Future<ParsedDocumentEntity> parseTXT(String filePath) async {
    // Check cache first (skip if format is UNKNOWN or invalid)
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached TXT: $filePath');
      return cached;
    }

    log.i('Parsing TXT (Dart): $filePath');

    // TXT: Pure Dart, no native needed - lightweight format
    final textContent = await compute(DocumentParserService.parseTXT, filePath);
    final result = ParsedDocumentEntity(
      format: 'TXT',
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      plainTextContent: textContent,
      fidelityLevel: DocumentFidelityLevel.plainText,
      wordCount: _countWords(textContent),
      lineCount: _countLines(textContent),
    );
    await cacheParsing(filePath, result);
    return result;
  }

  @override
  Future<ParsedDocumentEntity> parseRTF(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached RTF: $filePath');
      return cached;
    }

    log.i('Parsing RTF (structured Dart parser): $filePath');

    final structuredResult = await WordDocumentParserService.parseRtf(filePath);
    final result = ParsedDocumentEntity(
      format: 'RTF',
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      plainTextContent: structuredResult.plainTextContent,
      documentBlocks: structuredResult.documentBlocks,
      parseWarnings: structuredResult.parseWarnings,
      fidelityLevel: structuredResult.fidelityLevel,
      wordCount: _countWords(structuredResult.plainTextContent),
      lineCount: _countLines(structuredResult.plainTextContent),
    );
    await cacheParsing(filePath, result);
    return result;
  }

  @override
  Future<ParsedDocumentEntity> parseODT(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached ODT: $filePath');
      return cached;
    }

    log.i('Parsing ODT (structured Dart parser): $filePath');
    final structuredResult = await WordDocumentParserService.parseOdt(filePath);
    final result = ParsedDocumentEntity(
      format: 'ODT',
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      plainTextContent: structuredResult.plainTextContent,
      documentBlocks: structuredResult.documentBlocks,
      parseWarnings: structuredResult.parseWarnings,
      fidelityLevel: structuredResult.fidelityLevel,
      wordCount: _countWords(structuredResult.plainTextContent),
      lineCount: _countLines(structuredResult.plainTextContent),
    );
    await cacheParsing(filePath, result);
    return result;
  }

  @override
  Future<ParsedDocumentEntity> parseOTT(String filePath) =>
      _parseOdfText(filePath, 'OTT');

  @override
  Future<ParsedDocumentEntity> parseODP(String filePath) =>
      _parseOdfText(filePath, 'ODP');

  /// Shared OpenDocument text extraction (ODP/OTT share ODT's content.xml layout)
  Future<ParsedDocumentEntity> _parseOdfText(
    String filePath,
    String format,
  ) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached $format: $filePath');
      return cached;
    }

    log.i('Parsing $format (structured Dart parser): $filePath');
    final structuredResult = await WordDocumentParserService.parseOdt(filePath);
    final result = ParsedDocumentEntity(
      format: format,
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      plainTextContent: structuredResult.plainTextContent,
      documentBlocks: structuredResult.documentBlocks,
      parseWarnings: structuredResult.parseWarnings,
      fidelityLevel: structuredResult.fidelityLevel,
      wordCount: _countWords(structuredResult.plainTextContent),
      lineCount: _countLines(structuredResult.plainTextContent),
    );
    await cacheParsing(filePath, result);
    return result;
  }

  @override
  Future<ParsedDocumentEntity> parsePPTX(String filePath) =>
      _visualPresentationStub(filePath, 'PPTX');

  @override
  Future<ParsedDocumentEntity> parsePPTXStructured(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null &&
        cached.format == 'PPTX' &&
        (cached.hasRichDocument ||
            cached.slides.isNotEmpty ||
            (cached.plainTextContent?.isNotEmpty ?? false))) {
      log.i('Using cached structured PPTX: $filePath');
      return cached;
    }

    log.i('Parsing PPTX structured fallback (native SlideShow): $filePath');
    try {
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, 'PPTX');
      final result = _toParsedEntity(nativeResult, format: 'PPTX').copyWith(
        fidelityLevel: (nativeResult['documentBlocks'] as List?)?.isNotEmpty == true
            ? DocumentFidelityLevel.partial
            : DocumentFidelityLevel.plainText,
        parseWarnings: ((nativeResult['parseWarnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
      log.i(
        'Successfully parsed PPTX fallback: ${result.slideCount} slides, '
        '${result.documentBlocks.length} blocks',
      );
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('NATIVE PARSING FAILED for PPTX fallback: $e',
          error: e, stackTrace: st);
      rethrow;
    }
  }

  @override
  Future<ParsedDocumentEntity> parsePPT(String filePath) async {
    // Legacy binary PPT cannot be rendered by the PPTX WebView engine.
    // Parse slides/text via native Apache POI instead of returning an empty stub.
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached PPT: $filePath');
      return cached;
    }

    log.i('Parsing PPT (native SlideShow): $filePath');
    try {
      final nativeResult =
          await _platformChannel.parseDocumentNative(filePath, 'PPT');
      final result = _toParsedEntity(nativeResult, format: 'PPT').copyWith(
        fidelityLevel: (nativeResult['documentBlocks'] as List?)?.isNotEmpty ==
                true
            ? DocumentFidelityLevel.partial
            : DocumentFidelityLevel.plainText,
        parseWarnings: ((nativeResult['parseWarnings'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
      log.i(
        'Successfully parsed PPT: ${result.slideCount} slides, '
        '${result.documentBlocks.length} blocks',
      );
      await cacheParsing(filePath, result);
      return result;
    } catch (e, st) {
      log.e('NATIVE PARSING FAILED for PPT: $e', error: e, stackTrace: st);
      rethrow;
    }
  }

  /// PPTX visual preview is rendered by the bundled WebView (slide layout).
  /// Skip Apache POI text extraction so decks open quickly.
  Future<ParsedDocumentEntity> _visualPresentationStub(
    String filePath,
    String format,
  ) async {
    log.i('$format: returning visual stub (WebView renders slides): $filePath');
    return ParsedDocumentEntity(
      format: format,
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      fidelityLevel: DocumentFidelityLevel.rich,
    );
  }

  @override
  Future<ParsedDocumentEntity> parseEPUB(String filePath) async {
    final cached = await getCachedParsing(filePath);
    if (cached != null && cached.format != 'UNKNOWN') {
      log.i('Using cached EPUB: $filePath');
      return cached;
    }

    log.i('Parsing EPUB (structured Dart parser): $filePath');
    final structuredResult = await WordDocumentParserService.parseEpub(filePath);
    final result = ParsedDocumentEntity(
      format: 'EPUB',
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: filePath,
      plainTextContent: structuredResult.plainTextContent,
      documentBlocks: structuredResult.documentBlocks,
      parseWarnings: structuredResult.parseWarnings,
      fidelityLevel: structuredResult.fidelityLevel,
      wordCount: _countWords(structuredResult.plainTextContent),
      lineCount: _countLines(structuredResult.plainTextContent),
    );
    await cacheParsing(filePath, result);
    return result;
  }

  @override
  Future<ParsedDocumentEntity?> getCachedParsing(String filePath) async {
    try {
      final cachedResult = await _cache.getCachedParsing(filePath);
      if (cachedResult != null) {
        final plain = OfficeGlyphSanitizer.sanitize(
          (cachedResult['plainTextContent'] ?? cachedResult['textContent'])
              as String?,
        );
        return ParsedDocumentEntity(
          format: cachedResult['format'] ?? 'UNKNOWN',
          sheets: _buildSheetEntities(cachedResult['sheets'] ?? []),
          slides: _buildSlideEntities(cachedResult['slides'] ?? []),
          documentBlocks: _sanitizeBlocks(
            _buildDocumentBlocks(cachedResult['documentBlocks'] ?? []),
          ),
          parseWarnings: ((cachedResult['parseWarnings'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList(),
          fidelityLevel: _parseFidelityLevel(cachedResult['fidelityLevel']),
          sheetCount: cachedResult['sheetCount'] ?? 0,
          slideCount: cachedResult['slideCount'] ?? 0,
          wordCount: cachedResult['wordCount'] as int?,
          lineCount: cachedResult['lineCount'] as int?,
          parsedAt: DateTime.now(),
          sourceFilePath: filePath,
          plainTextContent: plain.isEmpty ? null : plain,
        );
      }
    } catch (e) {
      log.w('Failed to get cached parsing: $e');
    }
    return null;
  }

  @override
  Future<void> cacheParsing(
    String filePath,
    ParsedDocumentEntity document,
  ) async {
    try {
      final data = {
        'format': document.format,
        'sheetCount': document.sheetCount,
        'slideCount': document.slideCount,
        'sheets': document.sheets
            .map((s) => {
                  'name': s.name,
                  'rows': s.rows,
                  'rowCount': s.rowCount,
                  'colCount': s.colCount,
                })
            .toList(),
        'slides': document.slides
            .map((s) => {
                  'slideNumber': s.slideNumber,
                  'text': s.text,
                })
            .toList(),
        'textContent': document.textContent,
        'plainTextContent': document.plainTextContent,
        'documentBlocks':
            document.documentBlocks.map((block) => block.toJson()).toList(),
        'parseWarnings': document.parseWarnings,
        'fidelityLevel': document.fidelityLevel.name,
        'wordCount': document.wordCount,
        'lineCount': document.lineCount,
      };

      await _cache.cacheParsing(filePath, data);
    } catch (e) {
      log.e('Failed to cache parsing: $e');
      // Don't throw - caching is optional
    }
  }

  @override
  Future<void> clearCache() => _cache.clearCache();

  @override
  Future<bool> isFileModified(String filePath, DateTime lastParsed) async {
    return !await _cache.isCacheValid(filePath, lastParsed);
  }

  /// Convert parser result map to ParsedDocumentEntity
  ParsedDocumentEntity _toParsedEntity(
    Map<String, dynamic> parserResult, {
    String? format,
  }) {
    final sheets = _buildSheetEntities(parserResult['sheets'] ?? []);
    final slides = _buildSlideEntities(parserResult['slides'] ?? []);

    final rawPlain = (parserResult['plainTextContent'] ??
        parserResult['textContent']) as String?;
    final plain = OfficeGlyphSanitizer.sanitize(rawPlain);
    final blocks = _sanitizeBlocks(
      _buildDocumentBlocks(parserResult['documentBlocks'] ?? []),
    );

    return ParsedDocumentEntity(
      format: format ?? parserResult['format'] ?? 'UNKNOWN',
      sheets: sheets,
      sheetCount: parserResult['sheetCount'] ?? sheets.length,
      slideCount: parserResult['slideCount'] ?? slides.length,
      slides: slides,
      documentBlocks: blocks,
      parseWarnings: ((parserResult['parseWarnings'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(),
      fidelityLevel: _parseFidelityLevel(parserResult['fidelityLevel']),
      parsedAt: DateTime.now(),
      sourceFilePath: parserResult['filePath'] ?? '',
      plainTextContent: plain.isEmpty ? null : plain,
      wordCount: (parserResult['wordCount'] as int?) ?? _countWords(plain),
      lineCount: (parserResult['lineCount'] as int?) ?? _countLines(plain),
    );
  }

  List<DocumentBlock> _sanitizeBlocks(List<DocumentBlock> blocks) {
    return blocks.map((block) {
      if (block is DocumentParagraphBlock) {
        return DocumentParagraphBlock(
          inlines: block.inlines
              .map(
                (inline) => DocumentInline(
                  type: inline.type,
                  text: OfficeGlyphSanitizer.sanitize(inline.text),
                  href: inline.href,
                  style: OfficeGlyphSanitizer.isSymbolFont(inline.style.fontFamily)
                      ? DocumentTextStyleData(
                          bold: inline.style.bold,
                          italic: inline.style.italic,
                          underline: inline.style.underline,
                          strike: inline.style.strike,
                          fontFamily: null,
                          fontSize: inline.style.fontSize,
                          colorHex: inline.style.colorHex,
                          backgroundHex: inline.style.backgroundHex,
                        )
                      : inline.style,
                ),
              )
              .toList(),
          alignment: block.alignment,
          spacingBefore: block.spacingBefore,
          spacingAfter: block.spacingAfter,
          firstLineIndent: block.firstLineIndent,
          leftIndent: block.leftIndent,
          rightIndent: block.rightIndent,
          listLevel: block.listLevel,
          listKind: block.listKind,
        );
      }
      if (block is DocumentTableBlock) {
        return DocumentTableBlock(
          rows: block.rows
              .map(
                (row) => DocumentTableRow(
                  cells: row.cells
                      .map(
                        (cell) => DocumentTableCell(
                          blocks: _sanitizeBlocks(cell.blocks),
                        ),
                      )
                      .toList(),
                ),
              )
              .toList(),
        );
      }
      return block;
    }).toList();
  }

  List<DocumentBlock> _buildDocumentBlocks(List<dynamic> blockData) {
    return blockData
        .whereType<Map>()
        .map(
            (block) => DocumentBlock.fromJson(_convertDynamicMapToTyped(block)))
        .toList();
  }

  DocumentFidelityLevel _parseFidelityLevel(dynamic raw) {
    if (raw is String) {
      return DocumentFidelityLevel.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => DocumentFidelityLevel.plainText,
      );
    }
    return DocumentFidelityLevel.plainText;
  }

  int? _countWords(String? text) {
    final value = text?.trim() ?? '';
    if (value.isEmpty) return null;
    return RegExp(r'\S+').allMatches(value).length;
  }

  int? _countLines(String? text) {
    final value = text ?? '';
    if (value.isEmpty) return null;
    return value.split(RegExp(r'\r\n|\r|\n')).length;
  }

  /// Build SheetEntity list from parser result
  List<SheetEntity> _buildSheetEntities(List<dynamic> sheetsData) {
    return sheetsData.map((sheetData) {
      // Handle both Map<String, dynamic> and Map<dynamic, dynamic>
      final sheet = sheetData is Map<String, dynamic>
          ? sheetData
          : _convertDynamicMapToTyped(sheetData as Map);

      final rows = (sheet['rows'] as List<dynamic>?)?.map((row) {
            if (row is List<String>) {
              return row;
            }
            // Handle mixed types in row data
            return (row as List<dynamic>).map((e) => e.toString()).toList();
          }).toList() ??
          [];

      // Determine max column count from all rows
      final maxColCount = rows.fold<int>(
        0,
        (max, row) => max > row.length ? max : row.length,
      );

      // Normalize all rows to have the same column count
      final normalizedRows = rows.map((row) {
        if (row.length == maxColCount) {
          return row;
        }
        final normalized = List<String>.from(row);
        if (normalized.length < maxColCount) {
          normalized
              .addAll(List<String>.filled(maxColCount - normalized.length, ''));
        } else {
          normalized.length = maxColCount;
        }
        return normalized;
      }).toList();

      return SheetEntity(
        name: sheet['name'] as String? ?? 'Sheet',
        rows: normalizedRows,
        rowCount: normalizedRows.length,
        colCount: maxColCount,
      );
    }).toList();
  }

  /// Convert Map with dynamic keys to typed Map with String keys
  Map<String, dynamic> _convertDynamicMapToTyped(Map map) {
    return Map<String, dynamic>.from(
      map.map((key, value) => MapEntry(
            key.toString(),
            _convertDynamicValue(value),
          )),
    );
  }

  /// Recursively convert dynamic values to typed values
  dynamic _convertDynamicValue(dynamic value) {
    if (value is Map) {
      return _convertDynamicMapToTyped(value);
    } else if (value is List) {
      return value.map(_convertDynamicValue).toList();
    } else {
      return value;
    }
  }

  /// Build SlideEntity list from parser result
  List<SlideEntity> _buildSlideEntities(List<dynamic> slidesData) {
    return slidesData.map((slideData) {
      final slide = slideData is Map<String, dynamic>
          ? slideData
          : _convertDynamicMapToTyped(slideData as Map);

      return SlideEntity(
        slideNumber: (slide['slideNumber'] as int?) ?? 0,
        text: (slide['text'] as String?) ?? '',
      );
    }).toList();
  }
}
