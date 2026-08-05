import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:logger/logger.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/core/presentation/widgets/connected_sheet_group.dart';
import 'package:air_docs_viewer/core/presentation/layout/shell_layout.dart';
import 'package:air_docs_viewer/core/presentation/widgets/floating_dock_scaffold.dart';
import 'package:air_docs_viewer/features/settings/domain/entities/app_settings.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/settings_providers.dart';
import 'package:air_docs_viewer/features/home/presentation/providers/thumbnail_provider.dart';
import 'package:air_docs_viewer/features/home/presentation/widgets/file_action_bottom_sheet.dart';
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

final log = Logger();

double _tiltAngleForDirection(BuildContext context) {
  return Directionality.of(context) == ui.TextDirection.rtl ? 0.15 : -0.15;
}

/// Home screen - displays recent files and quick actions
class HomeScreen extends ConsumerStatefulWidget {
  final bool tabMode;
  final VoidCallback? onSeeAll;

  const HomeScreen({super.key, this.tabMode = false, this.onSeeAll});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with TickerProviderStateMixin {
  bool _dataLoaded = false;
  late AnimationController _skeletonShimmerController;
  late Animation<double> _skeletonShimmer;

  DateTime? _lastBackPress;
  static const Duration _backPressExitDuration = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _skeletonShimmerController = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
    _skeletonShimmer = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(
          parent: _skeletonShimmerController, curve: Curves.easeInOut),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _skeletonShimmerController.stop();
      setState(() => _dataLoaded = true);
      Future.microtask(() => ref.read(recentFilesProvider));
    });
  }

  @override
  void dispose() {
    _skeletonShimmerController.dispose();
    super.dispose();
  }

  Widget _buildAppBarContent(BuildContext context) {
    return const SizedBox.shrink();
  }

  Widget _buildHomeLogoHero(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = MediaQuery.sizeOf(context);
        final maxWidth = (size.width * 0.52).clamp(200.0, 280.0);
        final maxHeight = (size.height * 0.14).clamp(100.0, 160.0);
        final width = maxWidth;
        final height = width < maxHeight ? width * 1.04 : maxHeight;

        return Padding(
          padding: EdgeInsets.only(
            bottom: 8,
            top: size.height < 700 ? 2 : 4,
          ),
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image.asset(
                'assets/air_docs_logo.png',
                width: width,
                height: height,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.high,
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (_lastBackPress == null ||
              DateTime.now().difference(_lastBackPress!) >
                  _backPressExitDuration) {
            _lastBackPress = DateTime.now();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(AppLocalizations.of(context)!.homePressBackExit),
                duration: _backPressExitDuration,
              ),
            );
          } else {
            SystemNavigator.pop();
          }
        }
      },
      child: widget.tabMode
          ? SizedBox.expand(child: _buildBody())
          : FloatingDockScaffold(
              appBarContent: _buildAppBarContent(context),
              currentRoute: RouteNames.home,
              tabCount: 2,
              body: _buildBody(),
            ),
    );
  }

  Widget _buildSkeletonLoading(BuildContext context) {
    final topPadding = widget.tabMode
        ? MediaQuery.paddingOf(context).top + 8
        : ShellLayout.topContentInset(context);
    final bottomPadding = ShellLayout.bottomContentInset(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final recentFilesBg =
        isDark ? const Color(0xFF0F0F11) : const Color(0xFFEFEFF4);

    return Column(
      children: [
        // Top content - matching real layout
        Padding(
          padding: EdgeInsets.fromLTRB(12, topPadding - 4, 12, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHomeLogoHero(context),
              _buildSkeletonActionCards(),
            ],
          ),
        ),

        // Recent Files Section - EXPANDED to fill remaining space
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              decoration: BoxDecoration(
                color: recentFilesBg,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              padding: EdgeInsets.fromLTRB(12, 16, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSkeletonRecentHeader(),
                  const SizedBox(height: 8),
                  // Skeleton fills expanded space (scrollable like real content)
                  Expanded(
                    child: ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(bottom: bottomPadding),
                      itemCount: 3,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: EdgeInsets.only(bottom: index < 2 ? 8 : 0),
                          child: _buildSkeletonRecentItem(),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (!_dataLoaded) {
      return _buildSkeletonLoading(context);
    }

    return Consumer(
      builder: (context, ref, _) {
        final recentFiles = ref.watch(recentFilesProvider);
        final showRecentFiles = ref.watch(showRecentFilesProvider);
        return recentFiles.when(
          data: (files) =>
              _buildHomeContent(context, files, showRecentFiles),
          error: (error, st) => _buildErrorState(context, error),
          loading: () => _buildSkeletonLoading(context),
        );
      },
    );
  }

  Widget _buildHomeContent(
      BuildContext context, List<RecentFile> files, bool showRecentFiles) {
    final topPadding = widget.tabMode
        ? MediaQuery.paddingOf(context).top + 8
        : ShellLayout.topContentInset(context);
    final bottomPadding =
        ShellLayout.bottomContentInset(context, includeFooter: true);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final recentFilesBg =
        isDark ? const Color(0xFF0F0F11) : const Color(0xFFEFEFF4);

    return Column(
      children: [
        // Top content can scroll on short phones / large text so it never
        // overflows above the Imported Files section.
        Flexible(
          fit: FlexFit.loose,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, topPadding - 4, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHomeLogoHero(context),

                  // Import document — full-width action card (scan removed)
                  _buildActionCard(
                    context,
                    title: AppLocalizations.of(context)!.homeImportDocument,
                    description:
                        AppLocalizations.of(context)!.homeImportDocumentDesc,
                    icon: Icons.folder_open,
                    cardType: 'import',
                    onTap: () {
                      log.i('Navigating to browse');
                      context.push(RouteNames.browse);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),

        // Recent Files Section - EXPANDED so bg always fills to bottom
        if (showRecentFiles)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                decoration: BoxDecoration(
                  color: recentFilesBg,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(20),
                    topRight: Radius.circular(20),
                  ),
                ),
                padding: EdgeInsets.fromLTRB(12, 16, 12, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fixed header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          files.isNotEmpty
                              ? AppLocalizations.of(context)!.recentFiles
                              : '',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        if (files.isNotEmpty)
                          TextButton(
                            onPressed: () {
                              if (widget.tabMode && widget.onSeeAll != null) {
                                widget.onSeeAll!();
                              } else {
                                context.push(RouteNames.documents);
                              }
                            },
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(AppLocalizations.of(context)!.homeSeeAll),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right,
                                  size: 18,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Content fills remaining space (3 states)
                    Expanded(
                      child: files.isNotEmpty
                          // State 1: Has files → show scrollable file list
                          ? Builder(builder: (context) {
                              final shownCount =
                                  files.length > 4 ? 4 : files.length;
                              return ListView.builder(
                                physics: const BouncingScrollPhysics(),
                                padding: EdgeInsets.only(bottom: bottomPadding),
                                itemCount: shownCount,
                                itemBuilder: (context, index) {
                                  return Padding(
                                    padding: EdgeInsets.only(
                                      bottom: index < shownCount - 1 ? 8 : 0,
                                    ),
                                    child: _buildRecentFileItem(
                                        context, files[index]),
                                  );
                                },
                              );
                            })
                          : Align(
                              alignment: Alignment.topCenter,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: 8),
                                  Text(
                                    AppLocalizations.of(context)!
                                        .homeWelcomeTitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 24),
                                    child: Text(
                                      AppLocalizations.of(context)!
                                          .homeWelcomeSubtitle,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.75),
                                            height: 1.4,
                                          ),
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildActionCard(
    BuildContext context, {
    required String title,
    required String description,
    required IconData icon,
    required String cardType,
    required VoidCallback onTap,
  }) {
    return _ModernActionCard(
      title: title,
      description: description,
      icon: icon,
      cardType: cardType,
      onTap: onTap,
    );
  }

  Widget _buildRecentFileItem(BuildContext context, RecentFile file) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          log.i('Opening recent file: ${file.fileName}');
          if (!file.isRead) {
            ref.read(recentFilesMutatorProvider).markAsRead(file.id);
          }
          context.push(
              '${RouteNames.viewer}?path=${Uri.encodeComponent(file.filePath)}&name=${Uri.encodeComponent(file.fileName)}');
        },
        onLongPress: () {
          log.i('Long-press options for: ${file.fileName}');
          _showFileActionBottomSheet(context, file);
        },
        borderRadius: BorderRadius.circular(8),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color:
                  Theme.of(context).colorScheme.outline.withValues(alpha: 0.2),
            ),
            color: Theme.of(context).colorScheme.surface,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              children: [
                // Thumbnail
                _RecentFileThumbnail(file: file),
                const SizedBox(width: 6),
                // File info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        file.fileName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Icon(
                            Icons.storage,
                            size: 10,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            file.formattedSize,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 10,
                                ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.schedule_outlined,
                            size: 10,
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 2),
                          Text(
                            _getTimeAgo(context, file.dateOpened),
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                  fontSize: 10,
                                ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.more_vert,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  onPressed: () => _showFileActionBottomSheet(context, file),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 40, minHeight: 40),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getTimeAgo(BuildContext context, DateTime dateTime) {
    final l10n = AppLocalizations.of(context)!;
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inSeconds < 60) {
      return l10n.timeAgoJustNow;
    } else if (difference.inMinutes < 60) {
      return l10n.timeAgoMinute(difference.inMinutes);
    } else if (difference.inHours < 24) {
      return l10n.timeAgoHour(difference.inHours);
    } else if (difference.inDays < 7) {
      return l10n.timeAgoDay(difference.inDays);
    } else if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      return l10n.timeAgoWeek(weeks);
    } else if (difference.inDays < 365) {
      final months = (difference.inDays / 30).floor();
      return l10n.timeAgoMonth(months);
    } else {
      final years = (difference.inDays / 365).floor();
      return l10n.timeAgoYear(years);
    }
  }

  void _softDeleteRecentFile(RecentFile file) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(context)!.homeDeleteFile),
        content: Text(
            AppLocalizations.of(context)!.homeDeleteFileConfirm(file.fileName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              ref.read(recentFilesMutatorProvider).softDeleteFile(file.id);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppLocalizations.of(context)!
                      .homeFileMovedToTrash(file.fileName)),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(AppLocalizations.of(context)!.delete),
          ),
        ],
      ),
    );
  }

  void _showFileInfoDialog(BuildContext context, RecentFile file) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.only(
          top: 6,
          bottom: MediaQuery.of(context).padding.bottom + 6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetHandle(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(
                  l10n.homeFileInfo,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              ConnectedSheetGroup(
                children: [
                  _infoCard(
                    context,
                    icon: Icons.description_outlined,
                    title: l10n.homeFileName,
                    value: file.fileName,
                  ),
                  _infoCard(
                    context,
                    icon: Icons.data_object,
                    title: l10n.homeFileType,
                    value: file.fileType.toUpperCase(),
                  ),
                  _infoCard(
                    context,
                    icon: Icons.storage_outlined,
                    title: l10n.homeFileSize,
                    value: file.formattedSize,
                  ),
                  _infoCard(
                    context,
                    icon: Icons.folder_open,
                    title: l10n.homeFileLocation,
                    value: file.filePath,
                    selectable: true,
                  ),
                  _infoCard(
                    context,
                    icon: Icons.schedule,
                    title: l10n.homeFileDateOpened,
                    value: _formatDateTime(file.dateOpened),
                  ),
                  _infoCard(
                    context,
                    icon: Icons.update,
                    title: l10n.homeFileLastModified,
                    value: _formatDateTime(file.dateModified),
                  ),
                  if (file.isDeleted)
                    _infoCard(
                      context,
                      icon: Icons.delete_outline,
                      title: l10n.homeFileInTrash,
                      value:
                          'yes (${l10n.homeFileDateOpened}: ${file.deletedAt != null ? _formatDateTime(file.deletedAt!) : 'unknown'})',
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ConnectedSheetGroup(
                children: [
                  _sheetActionCard(
                    context,
                    icon: Icons.content_copy,
                    title: l10n.copy,
                    subtitle: l10n.homeCopyFileInfoPrompt,
                    iconColor: colorScheme.primary,
                    onTap: () async {
                      final text = _buildFileInfoText(context, file);
                      final navigator = Navigator.of(ctx);
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(ClipboardData(text: text));
                      navigator.pop();
                      messenger.showSnackBar(
                        SnackBar(content: Text(l10n.homeFileInfoCopied)),
                      );
                    },
                  ),
                  _sheetActionCard(
                    context,
                    icon: Icons.close,
                    title: l10n.close,
                    iconColor: colorScheme.onSurfaceVariant,
                    onTap: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    final day = dt.day;
    final suffix = (day % 100 >= 11 && day % 100 <= 13)
        ? 'th'
        : (day % 10 == 1)
            ? 'st'
            : (day % 10 == 2)
                ? 'nd'
                : (day % 10 == 3)
                    ? 'rd'
                    : 'th';
    final datePart = DateFormat('MMMM yyyy').format(dt);
    final timePart = DateFormat('h:mm a').format(dt);
    return '$day$suffix $datePart, $timePart';
  }

  Widget _sheetHandle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _infoCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    bool selectable = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConnectedSheetRow(
      leading: SheetIconChip.icon(
        icon: icon,
        color: colorScheme.primary,
        backgroundColor: colorScheme.primary.withValues(alpha: 0.14),
      ),
      title: title,
      detail: selectable
          ? SelectableText(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            )
          : Text(
              value,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
            ),
    );
  }

  Widget _sheetActionCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return ConnectedSheetRow(
      leading: SheetIconChip.icon(
        icon: icon,
        color: iconColor,
        backgroundColor: iconColor.withValues(alpha: 0.14),
      ),
      title: title,
      detail: subtitle == null ? null : Text(subtitle),
      detailColor: colorScheme.onSurfaceVariant,
      onTap: onTap,
    );
  }

  String _buildFileInfoText(BuildContext context, RecentFile file) {
    final l10n = AppLocalizations.of(context)!;
    final buffer = StringBuffer();
    buffer.writeln('${l10n.homeFileName}: ${file.fileName}');
    buffer.writeln('${l10n.homeFileType}: ${file.fileType.toUpperCase()}');
    buffer.writeln('${l10n.homeFileSize}: ${file.formattedSize}');
    buffer.writeln('${l10n.homeFileLocation}: ${file.filePath}');
    buffer.writeln(
        '${l10n.homeFileDateOpened}: ${_formatDateTime(file.dateOpened)}');
    buffer.writeln(
        '${l10n.homeFileLastModified}: ${_formatDateTime(file.dateModified)}');
    if (file.isDeleted) {
      buffer.writeln(
          '${l10n.homeFileInTrash}: yes (${l10n.homeFileDateOpened}: ${file.deletedAt != null ? _formatDateTime(file.deletedAt!) : 'unknown'})');
    }
    return buffer.toString();
  }

  Future<void> _duplicateFile(RecentFile file) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final src = File(file.filePath);
      if (!await src.exists()) {
        throw Exception('Source file does not exist');
      }

      final dir = src.parent.path;
      final originalName = src.path.split('/').last;
      final dot = originalName.lastIndexOf('.');
      final base = dot > 0 ? originalName.substring(0, dot) : originalName;
      final ext = dot > 0 ? originalName.substring(dot) : '';

      String candidateName(String suffixIndex) => '$base$suffixIndex$ext';

      String suffix = l10n.homeCopySuffix;
      String newName = candidateName(suffix);
      int counter = 2;
      while (await File('$dir/$newName').exists()) {
        newName = candidateName(l10n.homeCopySuffixCounter(counter));
        counter++;
      }

      final destPath = '$dir/$newName';
      final copied = await src.copy(destPath);

      final mutator = ref.read(recentFilesMutatorProvider);
      final newRecent = RecentFile(
        id: const Uuid().v4(),
        filePath: copied.path,
        fileName: newName,
        fileType: file.fileType,
        fileSizeBytes: await copied.length(),
        dateOpened: DateTime.now(),
        dateModified: await copied.lastModified(),
        pagePosition: 0,
        syncStatus: 'local',
        isDeleted: false,
      );

      await mutator.addRecentFile(newRecent);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.homeDuplicatedAs(newName))),
        );
      }
    } catch (e) {
      log.e('Failed to duplicate file', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!
                  .homeFailedDuplicate(e.toString()))),
        );
      }
    }
  }

  Future<void> _renameFile(RecentFile file) async {
    final dot = file.fileName.lastIndexOf('.');
    final baseName = dot > 0 ? file.fileName.substring(0, dot) : file.fileName;
    final extension = dot > 0 ? file.fileName.substring(dot) : '';
    final controller = TextEditingController(text: baseName);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx)!;
        return AlertDialog(
          title: Text(l10n.homeRenameFile),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l10n.homeFileNameLabel,
              suffixText: extension,
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: Text(l10n.rename),
            ),
          ],
        );
      },
    );

    if (newName == null ||
        newName.trim().isEmpty ||
        newName.trim() == baseName) {
      return;
    }

    final fullNewName = '${newName.trim()}$extension';
    final sourceFile = File(file.filePath);
    final dir = sourceFile.parent.path;
    final newPath = '$dir/$fullNewName';

    if (await File(newPath).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text(AppLocalizations.of(context)!.homeFileAlreadyExists)),
        );
      }
      return;
    }

    try {
      await sourceFile.rename(newPath);
      final mutator = ref.read(recentFilesMutatorProvider);
      final updatedFile = RecentFile(
        id: file.id,
        filePath: newPath,
        fileName: fullNewName,
        fileType: file.fileType,
        fileSizeBytes: file.fileSizeBytes,
        dateOpened: file.dateOpened,
        dateModified: await File(newPath).lastModified(),
        pagePosition: file.pagePosition,
        syncStatus: file.syncStatus,
        isRead: file.isRead,
      );
      await mutator.removeRecentFile(file.id);
      await mutator.addRecentFile(updatedFile);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  AppLocalizations.of(context)!.homeRenamedTo(fullNewName))),
        );
      }
    } catch (e) {
      log.e('Failed to rename file', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!.homeFailedRename)),
        );
      }
    }
  }

  Future<void> _exportFile(RecentFile file) async {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.22),
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _sheetHandle(context),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                  child: Text(l10n.homeExport,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ),
                ConnectedSheetGroup(
                  children: [
                    _buildExportActionRow(
                      icon: Icons.download,
                      title: l10n.homeSaveToDownloads,
                      iconColor: Colors.green,
                      subtitle: l10n.homeSaveToDownloadsPath(file.fileName),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _saveToDownloads(file);
                      },
                    ),
                    _buildExportActionRow(
                      icon: Icons.folder_open,
                      title: l10n.homeChooseLocation,
                      iconColor: Colors.blue,
                      subtitle: l10n.homeChooseLocationDesc,
                      onTap: () async {
                        Navigator.pop(ctx);
                        await _saveToCustomLocation(file);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildExportActionRow({
    required IconData icon,
    required String title,
    required Color iconColor,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return ConnectedSheetRow(
      leading: SheetIconChip.icon(
        icon: icon,
        color: iconColor,
        backgroundColor: iconColor.withValues(alpha: 0.14),
      ),
      title: title,
      detail: subtitle == null ? null : Text(subtitle),
      detailColor: Theme.of(context).colorScheme.onSurfaceVariant,
      onTap: onTap,
    );
  }

  Future<Directory> _getAirDocsViewerDownloadsDir() async {
    final dir = await getDownloadsDirectory();
    if (dir == null) {
      throw UnsupportedError('Downloads directory not available');
    }
    return Directory('${dir.path}/AirDocsViewer');
  }

  Future<void> _saveToDownloads(RecentFile file) async {
    try {
      final downloadsDir = await _getAirDocsViewerDownloadsDir();
      if (!await downloadsDir.exists()) {
        await downloadsDir.create(recursive: true);
      }
      final source = File(file.filePath);
      final dest = '${downloadsDir.path}/${file.fileName}';
      var finalDest = dest;
      var counter = 1;
      while (await File(finalDest).exists()) {
        final dot = file.fileName.lastIndexOf('.');
        final base = dot > 0 ? file.fileName.substring(0, dot) : file.fileName;
        final ext = dot > 0 ? file.fileName.substring(dot) : '';
        finalDest = '${downloadsDir.path}/$base ($counter)$ext';
        counter++;
      }
      await source.copy(finalDest);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!
                  .homeSavedToDownloads(finalDest.split('/').last))),
        );
      }
    } catch (e) {
      log.e('Failed to export file', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!.homeFailedExport)),
        );
      }
    }
  }

  Future<void> _saveToCustomLocation(RecentFile file) async {
    try {
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: AppLocalizations.of(context)!.homeChooseSaveLocation,
      );
      if (directory == null) return;

      final source = File(file.filePath);
      var dest = '$directory/${file.fileName}';
      var counter = 1;
      while (await File(dest).exists()) {
        final dot = file.fileName.lastIndexOf('.');
        final base = dot > 0 ? file.fileName.substring(0, dot) : file.fileName;
        final ext = dot > 0 ? file.fileName.substring(dot) : '';
        dest = '$directory/$base ($counter)$ext';
        counter++;
      }
      await source.copy(dest);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!
                  .homeSavedTo(dest.split('/').last))),
        );
      }
    } catch (e) {
      log.e('Failed to export file to custom location', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(AppLocalizations.of(context)!.homeFailedExport)),
        );
      }
    }
  }

  void _showFileActionBottomSheet(BuildContext context, RecentFile file) {
    showFileActionBottomSheet(
      context: context,
      file: file,
      callbacks: FileActionCallbacks(
        onRename: () => _renameFile(file),
        onDuplicate: () => _duplicateFile(file),
        onExport: () => _exportFile(file),
        onFileInfo: () => _showFileInfoDialog(context, file),
        onDelete: () => _softDeleteRecentFile(file),
      ),
    );
  }

  Widget _buildErrorState(BuildContext context, Object error) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 100),
      children: [
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(AppLocalizations.of(context)!
                  .homeErrorPrefix(error.toString())),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSkeletonActionCards() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color cardBg =
        isDark ? const Color(0xFF18181B) : const Color(0xFFFAFAFA);
    final Color borderColor =
        isDark ? const Color(0xFF3F3F46) : const Color(0xFFD4D4D8);

    return Container(
      height: 96,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: cardBg,
        border: Border.all(
          color: borderColor.withValues(alpha: 0.5),
          width: 1,
        ),
      ),
    );
  }

  Widget _buildSkeletonRecentHeader() {
    final shimmer = _skeletonShimmer.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color baseColor =
        isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7);
    final Color highlightColor =
        isDark ? const Color(0xFF3F3F46) : const Color(0xFFF4F4F5);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // "Recent Files" text skeleton
        Container(
          width: 80,
          height: 16,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(
              begin: Alignment(shimmer - 1, 0),
              end: Alignment(shimmer, 0),
              colors: [baseColor, highlightColor, baseColor],
            ),
          ),
        ),
        // "See All" button skeleton (Text + chevron_right)
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                gradient: LinearGradient(
                  begin: Alignment(shimmer - 1, 0),
                  end: Alignment(shimmer, 0),
                  colors: [baseColor, highlightColor, baseColor],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  begin: Alignment(shimmer - 1, 0),
                  end: Alignment(shimmer, 0),
                  colors: [baseColor, highlightColor, baseColor],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSkeletonRecentItem() {
    final shimmer = _skeletonShimmer.value;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final Color baseColor =
        isDark ? const Color(0xFF27272A) : const Color(0xFFE4E4E7);
    final Color highlightColor =
        isDark ? const Color(0xFF3F3F46) : const Color(0xFFF4F4F5);
    final Color cardBg =
        isDark ? const Color(0xFF18181B) : const Color(0xFFFAFAFA);
    final Color borderColor =
        isDark ? const Color(0xFF3F3F46) : const Color(0xFFD4D4D8);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor.withValues(alpha: 0.5),
          width: 1,
        ),
        color: cardBg,
      ),
      child: Row(
        children: [
          // Thumbnail skeleton - single rotated rectangle matching the shape
          Transform.rotate(
            angle: _tiltAngleForDirection(context),
            child: Container(
              width: 70,
              height: 96,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                gradient: LinearGradient(
                  begin: Alignment(shimmer - 1, 0),
                  end: Alignment(shimmer, 0),
                  colors: [baseColor, highlightColor, baseColor],
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          // File info skeleton - exact clone of real layout
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Filename text
                Container(
                  width: double.infinity,
                  height: 12,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    gradient: LinearGradient(
                      begin: Alignment(shimmer - 1, 0),
                      end: Alignment(shimmer, 0),
                      colors: [baseColor, highlightColor, baseColor],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                // Metadata row: storage icon + size + clock icon + time-ago
                Row(
                  children: [
                    // Storage icon skeleton
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          begin: Alignment(shimmer - 1, 0),
                          end: Alignment(shimmer, 0),
                          colors: [baseColor, highlightColor, baseColor],
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    // Size text skeleton
                    Container(
                      width: 50,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          begin: Alignment(shimmer - 1, 0),
                          end: Alignment(shimmer, 0),
                          colors: [baseColor, highlightColor, baseColor],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Clock icon skeleton
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: LinearGradient(
                          begin: Alignment(shimmer - 1, 0),
                          end: Alignment(shimmer, 0),
                          colors: [baseColor, highlightColor, baseColor],
                        ),
                      ),
                    ),
                    const SizedBox(width: 2),
                    // Time-ago text skeleton
                    Container(
                      width: 50,
                      height: 10,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(4),
                        gradient: LinearGradient(
                          begin: Alignment(shimmer - 1, 0),
                          end: Alignment(shimmer, 0),
                          colors: [baseColor, highlightColor, baseColor],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Three-dot menu skeleton (more_vert icon)
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              gradient: LinearGradient(
                begin: Alignment(shimmer - 1, 0),
                end: Alignment(shimmer, 0),
                colors: [baseColor, highlightColor, baseColor],
              ),
            ),
          ),
        ],
      ),
    );
  }

}

/// Helper widget to display and trigger thumbnail generation for recent files
class _RecentFileThumbnail extends ConsumerStatefulWidget {
  final RecentFile file;

  const _RecentFileThumbnail({required this.file});

  @override
  ConsumerState<_RecentFileThumbnail> createState() =>
      _RecentFileThumbnailState();
}

class _RecentFileThumbnailState extends ConsumerState<_RecentFileThumbnail> {
  @override
  void initState() {
    super.initState();
    final type = widget.file.fileType.toLowerCase();
    if (type == 'ppt' || type == 'pptx' || type == 'odp') {
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch BOTH: the cache and the generation provider
    // This way when generation completes and saves, we automatically refresh
    final thumbnail = ref.watch(thumbnailProvider(widget.file.id));
    // Watch generation provider to auto-refresh when thumbnail generation completes
    ref.watch(generateAndCacheThumbnailProvider(
      (
        fileId: widget.file.id,
        filePath: widget.file.filePath,
        fileName: widget.file.fileName,
        fileType: widget.file.fileType,
        extractedText: widget.file.extractedText,
        brightness: Theme.of(context).brightness,
      ),
    ));

    return thumbnail.when(
      data: (bytes) {
        if (bytes != null) {
          return _buildIsometricThumbnail(
            Image.memory(
              bytes,
              width: 70,
              height: 96,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              filterQuality: FilterQuality.high,
            ),
          );
        }
        return _buildIsometricThumbnail(_buildThumbPlaceholder(_isPresentationFormat(widget.file.fileType)));
      },
      loading: () =>
          _buildIsometricThumbnail(_buildThumbPlaceholder(_isPresentationFormat(widget.file.fileType))),
      error: (error, stack) {
        log.e('🖼️  [Thumbnail Widget] Error loading thumbnail: $error');
        return _buildIsometricThumbnail(_buildThumbPlaceholder(_isPresentationFormat(widget.file.fileType)));
      },
    );
  }

  Widget _buildIsometricThumbnail(Widget child) {
    const double thumbnailWidth = 70.0;
    const double thumbnailHeight = 96.0;

    return SizedBox(
      width: thumbnailWidth,
      height: thumbnailHeight,
      child: Transform.rotate(
        angle: _tiltAngleForDirection(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
      ),
    );
  }

  Widget _buildThumbPlaceholder(bool isPresentation) {
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 70,
            height: 96,
            color: Theme.of(context)
                .colorScheme
                .primaryContainer
                .withValues(alpha: 0.3),
          ),
        ),
      ],
    );
  }

  bool _isPresentationFormat(String fileType) {
    final type = fileType.toLowerCase();
    return type == 'ppt' || type == 'pptx' || type == 'odp';
  }
}

/// Modern Android-style Action Card with vertical layout and chevron
class _ModernActionCard extends StatefulWidget {
  final String title;
  final String description;
  final IconData icon;
  final String cardType; // 'scan' or 'import'
  final VoidCallback onTap;

  const _ModernActionCard({
    required this.title,
    required this.description,
    required this.icon,
    required this.cardType,
    required this.onTap,
  });

  @override
  State<_ModernActionCard> createState() => _ModernActionCardState();
}

class _ModernActionCardState extends State<_ModernActionCard>
    with TickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late AnimationController _shimmerController;
  late Animation<double> _shimmerAnimation;
  late AnimationController _binaryController;
  late Animation<double> _binaryAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );

    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.94).animate(_controller);

    // Shimmer animation for continuous subtle effect
    _shimmerController = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat();

    _shimmerAnimation = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerController, curve: Curves.easeInOut),
    );

    // Binary animation for extraction card
    _binaryController = AnimationController(
      duration: const Duration(seconds: 15),
      vsync: this,
    )..repeat();

    _binaryAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _binaryController, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _shimmerController.dispose();
    _binaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isScanning = widget.cardType == 'scan';
    final textDirection = Directionality.of(context);
    final isRTL = textDirection == ui.TextDirection.rtl;

    // Use theme colors with better contrast and visual appeal
    final gradientColors = isScanning
        ? [
            const Color(0xFF16A085), // Emerald
            const Color(0xFF27AE60), // Green
          ]
        : [
            const Color(0xFF40916C), // Light forest green (matches theme)
            const Color(0xFF52B788), // Soft mint green
          ];

    return AnimatedBuilder(
      animation: Listenable.merge(
          [_scaleAnimation, _shimmerAnimation, _binaryAnimation]),
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTapDown: (_) {
                _controller.animateTo(1.0,
                    duration: const Duration(milliseconds: 80),
                    curve: Curves.easeOut);
              },
              onTapCancel: () {
                _controller.animateTo(0.0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.elasticOut);
              },
              onTap: () {
                _controller.animateTo(0.0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.elasticOut);
                // Let bounce play for 150ms then navigate
                Future.delayed(const Duration(milliseconds: 150), () {
                  if (mounted) widget.onTap();
                });
              },
              borderRadius: BorderRadius.circular(16),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                    colors: gradientColors,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    children: [
                      // Animation background (bottom layer) - small black section on trailing side
                      if (isScanning)
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: true,
                            child: CustomPaint(
                              painter: _BinaryDigitsPainter(
                                progress: _binaryAnimation.value,
                                textDirection: textDirection,
                              ),
                            ),
                          ),
                        )
                      else
                        Positioned.fill(
                          child: IgnorePointer(
                            ignoring: true,
                            child: CustomPaint(
                              painter: _IconAnimationPainter(
                                progress: _binaryAnimation.value,
                                preserveIdentity: true,
                                textDirection: textDirection,
                              ),
                            ),
                          ),
                        ),

                      LayoutBuilder(
                        builder: (context, constraints) {
                          // Keep copy on the gradient side — black wedge starts ~72% width.
                          final textMaxWidth = constraints.maxWidth * 0.58;
                          return Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(
                                12, 12, 12, 12),
                            child: ConstrainedBox(
                              constraints:
                                  BoxConstraints(maxWidth: textMaxWidth),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.white.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Icon(
                                      widget.icon,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    widget.title,
                                    textAlign: TextAlign.start,
                                    softWrap: true,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                          fontSize: 16,
                                          height: 1.2,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.description,
                                    textAlign: TextAlign.start,
                                    softWrap: true,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: Colors.white
                                              .withValues(alpha: 0.85),
                                          fontSize: 11,
                                          height: 1.3,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),

                      PositionedDirectional(
                        top: 8,
                        end: 10,
                        child: Icon(
                          isRTL
                              ? _kChevronLeftNoMirror
                              : _kChevronRightNoMirror,
                          size: 20,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// Binary digits painter for extraction card - shows animated 0s and 1s on pitch black trailing wedge.
class _BinaryDigitsPainter extends CustomPainter {
  final double progress;
  final ui.TextDirection textDirection;

  _BinaryDigitsPainter({
    required this.progress,
    this.textDirection = ui.TextDirection.ltr,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isRTL = textDirection == ui.TextDirection.rtl;
    double x(double logicalX) => isRTL ? size.width - logicalX : logicalX;

    final diagRect = Path();
    diagRect.moveTo(x(size.width), 0);
    diagRect.lineTo(x(size.width * 0.90), 0);
    diagRect.lineTo(x(size.width * 0.72), size.height);
    diagRect.lineTo(x(size.width), size.height);
    diagRect.close();

    final blackPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawPath(diagRect, blackPaint);

    // Clip animation to only appear in black area
    canvas.save();
    canvas.clipPath(diagRect);

    // Draw animated binary digits (0s and 1s) in 2 columns with offset
    const textStyle = TextStyle(
      color: Colors.white,
      fontSize: 10,
      fontFamily: 'monospace',
      fontWeight: FontWeight.bold,
      letterSpacing: 0.8,
    );

    final textPainter = TextPainter(textDirection: textDirection);

    const rows = 18;
    const cols = 2;
    const rowSpacing = 12.5;
    const colSpacing = 12.0;
    const topBase = 10.0;
    const switchSpeed = 10.0;
    const digits = ['0', '1'];

    int cellSeed(int row, int col) => (row * 31) + (col * 17);
    double cellPhase(int row, int col) {
      final seed = cellSeed(row, col);
      return ((seed % 100) / 100.0);
    }
    String digitFor(int row, int col, int step) {
      return digits[(row + col + step + cellSeed(row, col)) % 2];
    }

    final scrollOffset = progress * (rows * rowSpacing);

    for (int col = 0; col < cols; col++) {
      final colOffset = col == 0 ? 0.0 : rowSpacing / 2;
      for (int row = 0; row < rows; row++) {
        final rawY = (row * rowSpacing + colOffset + scrollOffset) % (rows * rowSpacing);
        final yPos = topBase + rawY;

        final cellProgress = (progress * switchSpeed) + cellPhase(row, col);
        final currentDigit = digitFor(row, col, cellProgress.floor());

        final xPos = x((size.width * 0.88) + (col * colSpacing));

        final distanceFromCenter = (yPos - size.height / 2).abs();
        final opacity =
            (1 - (distanceFromCenter / (size.height / 2))).clamp(0.0, 1.0);

        void paintDigit(String digit, double alpha) {
          if (alpha <= 0) return;
          textPainter.text = TextSpan(
            text: digit,
            style: textStyle.copyWith(
              color: Colors.white.withValues(alpha: alpha * 0.82),
            ),
          );
          textPainter.layout();
          textPainter.paint(
            canvas,
            Offset(
              xPos - textPainter.width / 2,
              yPos - textPainter.height / 2,
            ),
          );
        }

        paintDigit(currentDigit, opacity);
      }
    }

    canvas.restore(); // Restore clipping
  }

  @override
  bool shouldRepaint(_BinaryDigitsPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.textDirection != textDirection;
}

// Icon animation painter for import card - shows animated Material document icons on black trailing wedge.
class _IconAnimationPainter extends CustomPainter {
  final double progress;
  final bool preserveIdentity;
  final ui.TextDirection textDirection;

  _IconAnimationPainter({
    required this.progress,
    this.preserveIdentity = false,
    this.textDirection = ui.TextDirection.ltr,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final isRTL = textDirection == ui.TextDirection.rtl;
    double x(double logicalX) => isRTL ? size.width - logicalX : logicalX;

    final diagRect = Path();
    diagRect.moveTo(x(size.width), 0);
    diagRect.lineTo(x(size.width * 0.90), 0);
    diagRect.lineTo(x(size.width * 0.72), size.height);
    diagRect.lineTo(x(size.width), size.height);
    diagRect.close();

    final blackPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;
    canvas.drawPath(diagRect, blackPaint);

    // Clip animation to only appear in black area
    canvas.save();
    canvas.clipPath(diagRect);

    // Draw animated Material Design icons with 2 columns for consistency
    const iconSpacing = 24.0;
    const colWidth = 22.0;

    // Document type icons to use - real Material icons for different file types
    const iconList = [
      Icons.picture_as_pdf, // PDF
      Icons.table_chart, // Spreadsheet/Sheet
      Icons.description, // Word/Document
      Icons.code, // Code/Programming
      Icons.slideshow, // PowerPoint/Presentation
      Icons.image, // Image
      Icons.text_fields, // Text
      Icons.folder, // Folder
    ];

    // Compute rows needed to fill the visible height
    const rows = 12;
    const totalHeight = rows * iconSpacing;

    // Use same perceived speed as binary: move by totalHeight per animation progress unit
    final scrollOffset = progress * totalHeight;

    // Draw in 2 columns with offset (matching scan card pattern)
    for (int col = 0; col < 2; col++) {
      // Offset second column by half spacing for async animation
      final colOffset = col == 0 ? 0.0 : iconSpacing / 2;

      for (int i = 0; i < rows; i++) {
        // Static icon assignment per logical row - strictly index based
        final iconIndex = (i + col * 3) % iconList.length;

        // Y position moves downward smoothly with wrapping
        double yPos =
            (i * iconSpacing + colOffset + scrollOffset) % totalHeight;
        if (yPos < -iconSpacing) yPos += totalHeight;

        final xPos = x((size.width * 0.84) + (col * colWidth));

        // Fade in/out at edges for seamless effect
        final distanceFromCenter = (yPos - size.height / 2).abs();
        final opacity =
            (1 - (distanceFromCenter / (size.height / 2))).clamp(0.0, 1.0);

        // Draw icon as a real Material glyph
        _drawIconGlyph(canvas, Offset(xPos, yPos), iconList[iconIndex], opacity,
            textDirection);
      }
    }

    canvas.restore(); // Restore clipping
  }

  void _drawIconGlyph(Canvas canvas, Offset center, IconData icon,
      double opacity, ui.TextDirection textDirection) {
    // Render actual Material Design icons using TextPainter
    final textPainter = TextPainter(
      textDirection: textDirection,
    );

    // Create Material icon text span with proper styling
    textPainter.text = TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(
        inherit: false,
        color: Colors.white.withValues(alpha: opacity * 0.85),
        fontSize: 14.0,
        fontFamily: icon.fontFamily,
        package: icon.fontPackage,
      ),
    );

    textPainter.layout();

    // Draw the icon centered at the given position
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(_IconAnimationPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.textDirection != textDirection;
}

const IconData _kChevronLeftNoMirror = IconData(
  0xe15e,
  fontFamily: 'MaterialIcons',
);

const IconData _kChevronRightNoMirror = IconData(
  0xe15f,
  fontFamily: 'MaterialIcons',
);
