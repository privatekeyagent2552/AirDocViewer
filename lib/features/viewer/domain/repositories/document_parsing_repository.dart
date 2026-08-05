import '../entities/parsed_document_entity.dart';

/// Abstract repository defining the contract for document parsing
/// This allows swapping implementations (Dart, Native, Mock, etc.)
abstract class DocumentParsingRepository {
  /// Parse a spreadsheet file (XLSX, CSV, XLS)
  ///
  /// Throws exceptions on parsing errors
  /// Returns ParsedDocumentEntity with all sheets and metadata
  Future<ParsedDocumentEntity> parseSpreadsheet(String filePath);

  /// Parse XLSX specifically with optional native parsing
  ///
  /// This method can use either Dart or native (platform channel) parsing
  /// depending on platform availability and configuration
  Future<ParsedDocumentEntity> parseXLSX(
    String filePath, {
    bool useNativeParsing = false,
  });

  /// Parse CSV file
  Future<ParsedDocumentEntity> parseCSV(String filePath);

  /// Parse ODS (OpenDocument Spreadsheet) file
  Future<ParsedDocumentEntity> parseODS(String filePath);

  /// Parse JSON file
  Future<ParsedDocumentEntity> parseJSON(String filePath);

  /// Parse FADREC custom format (JSON-based)
  Future<ParsedDocumentEntity> parseFadrec(String filePath);

  /// Parse XML file
  Future<ParsedDocumentEntity> parseXML(String filePath);

  /// Parse DOCX file (visual stub — WebView renders layout)
  Future<ParsedDocumentEntity> parseDOCX(String filePath);

  /// Structured DOCX fallback when WebView render fails
  Future<ParsedDocumentEntity> parseDOCXStructured(String filePath);

  /// Parse DOC file (legacy Word format)
  Future<ParsedDocumentEntity> parseDOC(String filePath);

  /// Parse TXT file (plain text)
  Future<ParsedDocumentEntity> parseTXT(String filePath);

  /// Parse RTF file (Rich Text Format)
  Future<ParsedDocumentEntity> parseRTF(String filePath);

  /// Parse ODT file (OpenDocument Text)
  Future<ParsedDocumentEntity> parseODT(String filePath);

  /// Parse OTT file (OpenDocument Text Template)
  Future<ParsedDocumentEntity> parseOTT(String filePath);

  /// Parse ODP file (OpenDocument Presentation) as extracted text
  Future<ParsedDocumentEntity> parseODP(String filePath);

  /// Parse PPTX file (visual stub — WebView renders slides)
  Future<ParsedDocumentEntity> parsePPTX(String filePath);

  /// Structured PPTX fallback when WebView render fails
  Future<ParsedDocumentEntity> parsePPTXStructured(String filePath);

  /// Parse PPT file (legacy PowerPoint) as extracted text
  Future<ParsedDocumentEntity> parsePPT(String filePath);

  /// Parse EPUB file (e-book) as extracted text
  Future<ParsedDocumentEntity> parseEPUB(String filePath);

  /// Get cached parsing result if available and file unchanged
  ///
  /// Returns null if:
  /// - No cache exists for this file
  /// - File has been modified since caching
  /// - Cache has expired
  Future<ParsedDocumentEntity?> getCachedParsing(String filePath);

  /// Cache a parsing result for future access
  ///
  /// Should invalidate if file is modified
  Future<void> cacheParsing(String filePath, ParsedDocumentEntity document);

  /// Clear all cached parsing data
  Future<void> clearCache();

  /// Check if file has been modified since last parsing
  Future<bool> isFileModified(String filePath, DateTime lastParsed);
}
