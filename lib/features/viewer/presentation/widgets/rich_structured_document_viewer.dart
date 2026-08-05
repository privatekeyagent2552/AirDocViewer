import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logger/logger.dart';
import 'package:air_docs_viewer/features/viewer/data/services/office_glyph_sanitizer.dart';
import 'package:air_docs_viewer/features/viewer/domain/entities/parsed_document_entity.dart';
import 'package:air_docs_viewer/features/viewer/presentation/widgets/text_document_search_drawer.dart';

final _log = Logger();

/// Renders [ParsedDocumentEntity.documentBlocks] with styles, lists, tables,
/// hyperlinks, and Unicode emoji — used for DOC/RTF/ODT/EPUB and WebView fallback.
class RichStructuredDocumentViewer extends StatefulWidget {
  const RichStructuredDocumentViewer({
    super.key,
    required this.document,
    this.onTap,
    this.onSearchHighlight,
    this.fontSize = 15,
  });

  final ParsedDocumentEntity document;
  final VoidCallback? onTap;
  final VoidCallback? onSearchHighlight;
  final double fontSize;

  @override
  State<RichStructuredDocumentViewer> createState() =>
      RichStructuredDocumentViewerState();
}

class RichStructuredDocumentViewerState
    extends State<RichStructuredDocumentViewer> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _drawerScrollController = ScrollController();
  final ValueNotifier<int> _drawerVersion = ValueNotifier<int>(0);

  late List<_SearchLine> _searchLines;
  List<TextSearchResult> _searchResults = const [];
  int _activeSearchResultIndex = -1;
  bool _isSearching = false;
  final Map<int, GlobalKey> _lineKeys = {};

  @override
  void initState() {
    super.initState();
    _rebuildSearchIndex();
  }

  @override
  void didUpdateWidget(covariant RichStructuredDocumentViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      _rebuildSearchIndex();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _drawerScrollController.dispose();
    _drawerVersion.dispose();
    super.dispose();
  }

  void _rebuildSearchIndex() {
    _searchLines = [];
    void walk(List<DocumentBlock> blocks, {int depth = 0}) {
      for (final block in blocks) {
        if (block is DocumentParagraphBlock) {
          final text = block.plainText.trimRight();
          if (text.isNotEmpty) {
            _searchLines.add(_SearchLine(text: text, depth: depth));
          }
        } else if (block is DocumentTableBlock) {
          for (final row in block.rows) {
            for (final cell in row.cells) {
              walk(cell.blocks, depth: depth + 1);
            }
          }
        }
      }
    }

    walk(widget.document.documentBlocks);
    _lineKeys
      ..clear()
      ..addEntries(
        List.generate(_searchLines.length, (i) => MapEntry(i, GlobalKey())),
      );
  }

  Widget buildDrawerContent(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _drawerVersion,
      builder: (context, _, __) {
        return TextDocumentSearchDrawer(
          searchController: _searchController,
          scrollController: _drawerScrollController,
          results: _searchResults,
          activeResultIndex: _activeSearchResultIndex,
          isSearching: _isSearching,
          linesChecked: _searchLines.length,
          totalLines: _searchLines.length,
          onQueryChanged: _performSearch,
          onResultTap: _goToSearchResult,
          onNextResult: () {
            if (_searchResults.isEmpty) return;
            _goToSearchResult(
              (_activeSearchResultIndex + 1) % _searchResults.length,
            );
          },
          onPreviousResult: () {
            if (_searchResults.isEmpty) return;
            final next = _activeSearchResultIndex <= 0
                ? _searchResults.length - 1
                : _activeSearchResultIndex - 1;
            _goToSearchResult(next);
          },
        );
      },
    );
  }

  void _performSearch(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) {
      setState(() {
        _searchResults = const [];
        _activeSearchResultIndex = -1;
        _isSearching = false;
      });
      _drawerVersion.value++;
      return;
    }

    setState(() => _isSearching = true);
    final results = <TextSearchResult>[];
    for (var i = 0; i < _searchLines.length; i++) {
      final line = _searchLines[i].text;
      final lower = line.toLowerCase();
      var start = 0;
      while (true) {
        final idx = lower.indexOf(normalized, start);
        if (idx < 0) break;
        results.add(
          TextSearchResult(
            lineNumber: i + 1,
            lineText: line.length > 120 ? '${line.substring(0, 117)}...' : line,
            matchStart: idx,
            matchLength: normalized.length,
          ),
        );
        start = idx + normalized.length;
      }
    }
    setState(() {
      _searchResults = results;
      _activeSearchResultIndex = results.isEmpty ? -1 : 0;
      _isSearching = false;
    });
    _drawerVersion.value++;
    if (results.isNotEmpty) {
      _goToSearchResult(0);
    }
  }

  void _goToSearchResult(int resultIndex) {
    if (resultIndex < 0 || resultIndex >= _searchResults.length) return;
    setState(() => _activeSearchResultIndex = resultIndex);
    _drawerVersion.value++;
    widget.onSearchHighlight?.call();
    final lineIndex = _searchResults[resultIndex].lineNumber - 1;
    final key = _lineKeys[lineIndex];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 280),
        alignment: 0.2,
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    try {
      // Strict offline: never open http/https/mailto or any external URL.
      await Clipboard.setData(ClipboardData(text: href));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('App is offline — link copied to clipboard'),
        ),
      );
    } catch (e) {
      _log.w('Failed to copy link $href: $e');
    }
  }

  String _sanitizeSymbolBullets(String text) =>
      OfficeGlyphSanitizer.sanitize(text);

  List<DocumentInline> _stripLeadingBulletFromInlines(
    List<DocumentInline> inlines,
  ) {
    if (inlines.isEmpty) return inlines;
    final first = inlines.first;
    if (first.type != DocumentInlineType.text) return inlines;
    final cleaned = OfficeGlyphSanitizer.stripLeadingBullet(
      OfficeGlyphSanitizer.sanitize(first.text),
    );
    if (cleaned == first.text) return inlines;
    return [
      DocumentInline(
        type: first.type,
        text: cleaned,
        href: first.href,
        style: first.style,
      ),
      ...inlines.skip(1),
    ];
  }

  String _listMarker(DocumentParagraphBlock paragraph, int indexAmongKind) {
    final kind = (paragraph.listKind ?? '').toLowerCase();
    final level = paragraph.listLevel ?? 0;
    final isNumbered = kind.contains('decimal') ||
        kind.contains('number') ||
        kind.startsWith('num:') ||
        kind.contains('arabic') ||
        kind == '1' ||
        kind.contains('ordered');
    if (isNumbered) {
      return '${indexAmongKind + 1}.';
    }
    const bullets = ['•', '◦', '▪', '‣'];
    return bullets[level.clamp(0, bullets.length - 1)];
  }

  TextAlign _alignOf(String? alignment) {
    return switch ((alignment ?? '').toLowerCase()) {
      'center' || 'centre' || 'middle' => TextAlign.center,
      'right' || 'end' => TextAlign.right,
      'justify' || 'both' => TextAlign.justify,
      _ => TextAlign.left,
    };
  }

  Color? _parseColor(String? hex, ThemeData theme) {
    if (hex == null || hex.isEmpty) return null;
    var value = hex.replaceAll('#', '').replaceAll('0x', '');
    if (value.length == 6) value = 'FF$value';
    if (value.length != 8) return null;
    try {
      final color = Color(int.parse(value, radix: 16));
      // Near-black Office text is invisible on the dark app theme.
      if (theme.brightness == Brightness.dark &&
          color.computeLuminance() < 0.18) {
        return theme.textTheme.bodyMedium?.color;
      }
      return color;
    } catch (_) {
      return null;
    }
  }

  List<InlineSpan> _spansFor(
    List<DocumentInline> inlines,
    ThemeData theme,
    double baseSize,
  ) {
    final spans = <InlineSpan>[];
    for (final inline in inlines) {
      final style = inline.style;
      final color = _parseColor(style.colorHex, theme) ??
          theme.textTheme.bodyMedium?.color;
      final bg = _parseColor(style.backgroundHex, theme);
      final fontSize =
          style.fontSize != null ? style.fontSize! * (baseSize / 12.0) : baseSize;

      switch (inline.type) {
        case DocumentInlineType.tab:
          spans.add(TextSpan(text: '\t', style: TextStyle(fontSize: fontSize)));
        case DocumentInlineType.lineBreak:
          spans.add(const TextSpan(text: '\n'));
        case DocumentInlineType.hyperlink:
          final href = inline.href;
          spans.add(
            TextSpan(
              text: _sanitizeSymbolBullets(
                inline.text.isEmpty ? (href ?? '') : inline.text,
              ),
              style: TextStyle(
                fontSize: fontSize,
                color: theme.colorScheme.primary,
                decoration: TextDecoration.underline,
                fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
                fontStyle:
                    style.italic ? FontStyle.italic : FontStyle.normal,
                fontFamily: style.fontFamily,
                backgroundColor: bg,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () => _openLink(href),
            ),
          );
        case DocumentInlineType.text:
          spans.add(
            TextSpan(
              text: _sanitizeSymbolBullets(inline.text),
              style: TextStyle(
                fontSize: fontSize,
                color: color,
                fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
                fontStyle:
                    style.italic ? FontStyle.italic : FontStyle.normal,
                decoration: () {
                  final decorations = <TextDecoration>[
                    if (style.underline) TextDecoration.underline,
                    if (style.strike) TextDecoration.lineThrough,
                  ];
                  if (decorations.isEmpty) return TextDecoration.none;
                  return TextDecoration.combine(decorations);
                }(),
                fontFamily: style.fontFamily,
                backgroundColor: bg,
                height: 1.35,
              ),
            ),
          );
      }
    }
    return spans;
  }

  Widget _buildParagraph(
    DocumentParagraphBlock paragraph,
    ThemeData theme,
    double baseSize, {
    required int listCounter,
    GlobalKey? key,
  }) {
    final level = paragraph.listLevel ?? 0;
    final hasList = paragraph.listKind != null || paragraph.listLevel != null;
    final marker = hasList ? _listMarker(paragraph, listCounter) : null;
    final indent = (paragraph.leftIndent ?? 0) +
        (hasList ? 12.0 + level * 18.0 : 0) +
        (paragraph.firstLineIndent ?? 0).clamp(0, 120);

    // If Word already embedded a Symbol/Wingdings bullet in the text, strip it
    // when we synthesize our own marker to avoid "•• item".
    final cleanedInlines = hasList
        ? _stripLeadingBulletFromInlines(paragraph.inlines)
        : paragraph.inlines;

    final text = Text.rich(
      TextSpan(children: _spansFor(cleanedInlines, theme, baseSize)),
      textAlign: _alignOf(paragraph.alignment),
    );

    final body = hasList
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  marker!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontSize: baseSize,
                    height: 1.35,
                  ),
                ),
              ),
              Expanded(child: text),
            ],
          )
        : text;

    return Padding(
      key: key,
      padding: EdgeInsets.only(
        left: indent.toDouble().clamp(0, 200),
        right: (paragraph.rightIndent ?? 0).clamp(0, 80),
        top: ((paragraph.spacingBefore ?? 0) / 20).clamp(0, 24),
        bottom: ((paragraph.spacingAfter ?? 6) / 20).clamp(2, 24),
      ),
      child: body,
    );
  }

  Widget _buildTable(DocumentTableBlock table, ThemeData theme, double baseSize) {
    if (table.rows.isEmpty) return const SizedBox.shrink();
    final colCount = table.rows
        .map((r) => r.cells.length)
        .fold<int>(0, (a, b) => a > b ? a : b);
    if (colCount == 0) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Table(
        border: TableBorder.all(
          color: theme.dividerColor.withValues(alpha: 0.7),
          width: 0.8,
        ),
        defaultVerticalAlignment: TableCellVerticalAlignment.top,
        children: [
          for (final row in table.rows)
            TableRow(
              children: [
                for (var c = 0; c < colCount; c++)
                  Padding(
                    padding: const EdgeInsets.all(6),
                    child: c < row.cells.length
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildBlocks(
                              row.cells[c].blocks,
                              theme,
                              baseSize * 0.95,
                              assignSearchKeys: false,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  List<Widget> _buildBlocks(
    List<DocumentBlock> blocks,
    ThemeData theme,
    double baseSize, {
    required bool assignSearchKeys,
  }) {
    final widgets = <Widget>[];
    final listCounters = <String, int>{};
    var searchLineCursor = 0;

    for (final block in blocks) {
      if (block is DocumentParagraphBlock) {
        final text = block.plainText.trimRight();
        GlobalKey? key;
        if (assignSearchKeys && text.isNotEmpty) {
          key = _lineKeys[searchLineCursor];
          searchLineCursor++;
        }
        final kindKey =
            '${block.listKind ?? 'none'}|${block.listLevel ?? -1}';
        final counter = listCounters[kindKey] ?? 0;
        if (block.listKind != null || block.listLevel != null) {
          listCounters[kindKey] = counter + 1;
        }
        widgets.add(
          _buildParagraph(
            block,
            theme,
            baseSize,
            listCounter: counter,
            key: key,
          ),
        );
      } else if (block is DocumentTableBlock) {
        widgets.add(_buildTable(block, theme, baseSize));
      } else if (block is DocumentSpacerBlock) {
        widgets.add(
          SizedBox(
            height: block.isPageBreak
                ? (block.height.clamp(24, 64))
                : block.height.clamp(4, 48),
          ),
        );
        if (block.isPageBreak) {
          widgets.add(
            Divider(color: theme.dividerColor.withValues(alpha: 0.4)),
          );
        }
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseSize = widget.fontSize;
    final blocks = widget.document.documentBlocks;

    if (blocks.isEmpty) {
      return Center(
        child: Text(
          widget.document.searchableText.isEmpty
              ? 'No content'
              : widget.document.searchableText,
          style: theme.textTheme.bodyMedium,
        ),
      );
    }

    return GestureDetector(
      onTap: widget.onTap,
      behavior: HitTestBehavior.opaque,
      child: SelectionArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 32),
          children: _buildBlocks(
            blocks,
            theme,
            baseSize,
            assignSearchKeys: true,
          ),
        ),
      ),
    );
  }
}

class _SearchLine {
  const _SearchLine({required this.text, required this.depth});
  final String text;
  final int depth;
}
