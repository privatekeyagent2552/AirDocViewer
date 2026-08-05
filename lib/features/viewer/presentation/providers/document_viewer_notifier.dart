import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:air_docs_viewer/core/services/storage_service.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/domain/supported_formats.dart';
import 'package:air_docs_viewer/features/viewer/data/providers/repository_providers.dart';

final log = Logger();

/// Content phase for the viewer surface — no format may hang in [preparing]
/// forever without advancing to ready / fallback / error.
enum ViewerPhase {
  preparing,
  rendering,
  ready,
  fallback,
  error,
}

/// State class for parsed document with loading/error handling
class ParsedDocumentState {
  final ParsedDocumentEntity? document;
  final bool isLoading;
  final String? error;
  final String? parsingStatus;
  final ViewerPhase phase;
  final bool usingFallback;

  const ParsedDocumentState({
    this.document,
    this.isLoading = false,
    this.error,
    this.parsingStatus,
    this.phase = ViewerPhase.preparing,
    this.usingFallback = false,
  });

  bool get hasError => error != null || phase == ViewerPhase.error;
  bool get hasData => document != null;

  ParsedDocumentState copyWith({
    ParsedDocumentEntity? document,
    bool? isLoading,
    String? error,
    String? parsingStatus,
    ViewerPhase? phase,
    bool? usingFallback,
    bool clearError = false,
  }) {
    return ParsedDocumentState(
      document: document ?? this.document,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
      parsingStatus: parsingStatus ?? this.parsingStatus,
      phase: phase ?? this.phase,
      usingFallback: usingFallback ?? this.usingFallback,
    );
  }
}

/// ViewModel for managing document parsing using modern Riverpod Notifier pattern.
class DocumentViewerNotifier extends Notifier<ParsedDocumentState> {
  String _filePath = '';
  String _fileName = '';
  int _loadGeneration = 0;

  @override
  ParsedDocumentState build() {
    return const ParsedDocumentState();
  }

  /// Initialize with file path and name, then load document.
  Future<void> initializeAndLoad(String filePath, String fileName) async {
    _filePath = filePath;
    _fileName = fileName;
    await loadDocument();
  }

  /// Force structured/text fallback for visual formats (DOCX/PPTX) when
  /// the pure-Flutter renderer fails.
  Future<void> loadStructuredFallback() async {
    final gen = ++_loadGeneration;
    final extension =
        SupportedFormats.extensionOf(_filePath) ??
        SupportedFormats.extensionOf(_fileName) ??
        '';
    final spec = SupportedFormats.of(extension);
    if (spec == null || spec.viewerKind != ViewerKind.richWeb) {
      return;
    }

    state = state.copyWith(
      isLoading: true,
      clearError: true,
      phase: ViewerPhase.preparing,
      parsingStatus: 'Loading readable fallback…',
    );

    try {
      final repository = ref.read(documentParsingRepositoryProvider);
      final document = switch (extension) {
        'doc' => await repository.parseDOC(_filePath),
        'docx' => await repository.parseDOCXStructured(_filePath),
        'ppt' => await repository.parsePPT(_filePath),
        'pptx' => await repository.parsePPTXStructured(_filePath),
        _ => throw UnsupportedError('No Office fallback for .$extension'),
      };
      if (gen != _loadGeneration) return;

      state = ParsedDocumentState(
        document: document,
        isLoading: false,
        phase: ViewerPhase.fallback,
        usingFallback: true,
      );
      log.i('Fallback open: $_fileName (format: ${document.format})');
    } catch (e, st) {
      if (gen != _loadGeneration) return;
      log.e('Fallback parse failed: $e', error: e, stackTrace: st);
      state = state.copyWith(
        isLoading: false,
        phase: ViewerPhase.error,
        error: e.toString(),
      );
    }
  }

  /// Mark visual content as fully rendered (called from viewer).
  void markReady() {
    if (state.phase == ViewerPhase.ready || state.phase == ViewerPhase.fallback) {
      return;
    }
    state = state.copyWith(phase: ViewerPhase.ready, isLoading: false);
  }

  /// Load and parse the document using the strategy from [SupportedFormats].
  Future<void> loadDocument() async {
    if (_filePath.isEmpty) {
      log.e('loadDocument called before initializeAndLoad');
      return;
    }

    final gen = ++_loadGeneration;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      phase: ViewerPhase.preparing,
      usingFallback: false,
    );

    try {
      final file = File(_filePath);
      if (!await file.exists()) {
        throw Exception('File not found: $_filePath');
      }

      final extension =
          SupportedFormats.extensionOf(_filePath) ??
          SupportedFormats.extensionOf(_fileName) ??
          '';
      final spec = SupportedFormats.of(extension);
      if (spec == null) {
        throw Exception(
          'Unsupported file format: ${extension.isEmpty ? '(no extension)' : extension}',
        );
      }

      state = state.copyWith(parsingStatus: 'Loading ${spec.formatLabel}…');

      final ParsedDocumentEntity document;
      switch (spec.openStrategy) {
        case OpenStrategy.direct:
          document = _directStub(spec);
          if (gen != _loadGeneration) return;
          state = ParsedDocumentState(
            document: document,
            isLoading: false,
            phase: ViewerPhase.rendering,
          );
          log.i('Direct open: $_fileName (format: ${document.format})');
          unawaited(_cacheInBackground());
          return;

        case OpenStrategy.visualWithFallback:
          // Show visual stub immediately; viewer may later request structured fallback.
          document = _directStub(spec);
          if (gen != _loadGeneration) return;
          state = ParsedDocumentState(
            document: document,
            isLoading: false,
            phase: ViewerPhase.rendering,
          );
          log.i('Visual open: $_fileName (format: ${document.format})');
          unawaited(_cacheInBackground());
          return;

        case OpenStrategy.parserFirst:
          document = await _parseBySpec(spec);
          if (gen != _loadGeneration) return;
          state = ParsedDocumentState(
            document: document,
            isLoading: false,
            phase: ViewerPhase.ready,
          );
          log.i(
            'Parsed open: $_fileName (format: ${document.format}, '
            'blocks=${document.documentBlocks.length}, '
            'sheets=${document.sheets.length})',
          );
          unawaited(_cacheInBackground());
          return;
      }
    } catch (e, st) {
      if (gen != _loadGeneration) return;
      log.e('Error loading document: $e', error: e, stackTrace: st);
      state = state.copyWith(
        isLoading: false,
        phase: ViewerPhase.error,
        error: e.toString(),
      );
    }
  }

  ParsedDocumentEntity _directStub(FormatSpec spec) {
    return ParsedDocumentEntity(
      format: spec.formatLabel,
      sheets: const [],
      sheetCount: 0,
      parsedAt: DateTime.now(),
      sourceFilePath: _filePath,
      fidelityLevel: spec.viewerKind == ViewerKind.richWeb
          ? DocumentFidelityLevel.rich
          : DocumentFidelityLevel.plainText,
    );
  }

  Future<ParsedDocumentEntity> _parseBySpec(FormatSpec spec) async {
    final repository = ref.read(documentParsingRepositoryProvider);
    final ext = spec.extension;

    switch (spec.viewerKind) {
      case ViewerKind.spreadsheet:
        if (ext == 'csv') return repository.parseCSV(_filePath);
        if (ext == 'ods') return repository.parseODS(_filePath);
        return repository.parseXLSX(_filePath, useNativeParsing: true);

      case ViewerKind.structured:
        return switch (ext) {
          'docx' => repository.parseDOCXStructured(_filePath),
          'doc' => repository.parseDOC(_filePath),
          'rtf' => repository.parseRTF(_filePath),
          'odt' => repository.parseODT(_filePath),
          'ott' => repository.parseOTT(_filePath),
          'odp' => repository.parseODP(_filePath),
          'pptx' => repository.parsePPTXStructured(_filePath),
          'ppt' => repository.parsePPT(_filePath),
          'epub' => repository.parseEPUB(_filePath),
          _ => throw Exception('No structured parser for .$ext'),
        };

      case ViewerKind.text:
        if (ext == 'json') return repository.parseJSON(_filePath);
        if (ext == 'xml' || ext == 'atom') {
          final doc = await repository.parseXML(_filePath);
          return ext == 'atom' ? doc.copyWith(format: 'ATOM') : doc;
        }
        if (ext == 'fadrec') return repository.parseFadrec(_filePath);
        final doc = await repository.parseTXT(_filePath);
        return ext == 'txt' ? doc : doc.copyWith(format: spec.formatLabel);

      case ViewerKind.pdf:
      case ViewerKind.richWeb:
      case ViewerKind.image:
      case ViewerKind.media:
        // These use direct / visual strategies; parser path is fallback only.
        return _directStub(spec);
    }
  }

  Future<void> _cacheInBackground() async {
    try {
      final alreadyManaged = await StorageService.isManagedPath(_filePath);
      if (alreadyManaged) {
        log.d('Skipping auto-cache for already-managed file: $_filePath');
        return;
      }
      final cachedFile =
          await StorageService.cacheDocument(_filePath, _fileName);
      log.i('Document cached: ${cachedFile.path}');
    } catch (e) {
      log.w('Failed to cache document: $e');
    }
  }
}

/// Provider for document viewing — autoDispose so state resets per viewer screen.
final documentViewerProvider =
    NotifierProvider.autoDispose<DocumentViewerNotifier, ParsedDocumentState>(
  DocumentViewerNotifier.new,
);
