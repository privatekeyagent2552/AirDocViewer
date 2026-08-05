import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/core/presentation/layout/shell_layout.dart';
import 'package:air_docs_viewer/core/presentation/widgets/connected_sheet_group.dart';
import 'package:air_docs_viewer/core/presentation/widgets/floating_dock_scaffold.dart';
import 'package:air_docs_viewer/core/services/storage_service.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/settings_providers.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/locale_provider.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends ConsumerWidget {
  final bool tabMode;
  const SettingsScreen({super.key, this.tabMode = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(appSettingsProvider);
    final packageInfoAsync = ref.watch(packageInfoProvider);

    final settingsBody = settings.when(
      data: (appSettings) {
        if (appSettings == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            ShellLayout.topContentInset(context),
            16,
            ShellLayout.bottomContentInset(context),
          ),
          children: [
            _buildSectionHeader(context, l10n.language),
            _buildSettingsGroup(context, [
              _SettingsRow(
                icon: Icons.language,
                title: l10n.language,
                value: _getLanguageDisplayName(context, ref),
                onTap: () => _showLanguagePicker(context, ref),
              ),
            ]),
            const SizedBox(height: 24),
            _buildSectionHeader(context, l10n.settingsStorage),
            _buildSettingsGroup(context, [
              Consumer(
                builder: (context, ref, _) {
                  final recentFilesAsync = ref.watch(recentFilesProvider);
                  return recentFilesAsync.when(
                    loading: () => _SettingsRow(
                      icon: Icons.folder_outlined,
                      title: l10n.settingsDocumentsSize,
                      value: l10n.settingsCalculating,
                      onTap: () => _showStorageInfo(context),
                    ),
                    error: (error, stack) => _SettingsRow(
                      icon: Icons.folder_outlined,
                      title: l10n.settingsDocumentsSize,
                      value: l10n.settingsUnknown,
                      onTap: () => _showStorageInfo(context),
                    ),
                    data: (files) {
                      final activeFiles =
                          files.where((f) => !f.isDeleted).toList();
                      final totalBytes = activeFiles.fold<int>(
                          0, (sum, f) => sum + f.fileSizeBytes);
                      final totalCount = activeFiles.length;
                      final value = l10n.settingsStorageFilesSummary(
                        StorageService.formatBytes(totalBytes),
                        totalCount,
                      );
                      return _SettingsRow(
                        icon: Icons.folder_outlined,
                        title: l10n.settingsDocumentsSize,
                        value: value,
                        onTap: () => _showStorageInfo(context),
                      );
                    },
                  );
                },
              ),
            ]),
            const SizedBox(height: 24),
            _buildSectionHeader(context, l10n.settingsAbout),
            _buildSettingsGroup(context, [
              _SettingsRow(
                icon: Icons.info_outline,
                title: l10n.settingsVersion,
                value: packageInfoAsync.when(
                  data: (info) => 'v${info.version}+${info.buildNumber}',
                  loading: () => '...',
                  error: (_, __) => l10n.settingsUnknown,
                ),
                onTap: () => packageInfoAsync.whenData(
                  (info) => _showVersionInfo(context, info),
                ),
              ),
              _divider(context),
              Consumer(
                builder: (context, ref, _) {
                  final settings = ref.watch(appSettingsProvider);
                  final show = settings.when(
                    data: (s) => s?.showOnboardingNextLaunch ?? false,
                    loading: () => false,
                    error: (_, __) => false,
                  );
                  return _buildOnboardingReplayRow(context, ref, show);
                },
              ),
              _divider(context),
              _SettingsRow(
                icon: Icons.business_outlined,
                title: l10n.settingsDeveloper,
                value: l10n.settingsDeveloperName,
                onTap: null,
              ),
              _divider(context),
              _SettingsRow(
                icon: Icons.shield_outlined,
                title: l10n.settingsPrivacyPolicy,
                onTap: () => _showPrivacyPolicy(context),
              ),
            ]),
            const SizedBox(height: 24),
            _buildSectionHeader(context, l10n.settingsDangerZone,
                color: Colors.red),
            _buildDangerGroup(context, [
              _DangerRow(
                icon: Icons.delete_outline,
                title: l10n.settingsTrash,
                subtitle: l10n.settingsTrashDesc,
                confirmText: '',
                onConfirm: () {
                  context.push(RouteNames.trash);
                },
              ),
              _divider(context),
              _DangerRow(
                icon: Icons.restore,
                title: l10n.settingsResetSettings,
                subtitle: l10n.settingsResetSettingsDesc,
                confirmText: 'RESET',
                onConfirm: () async {
                  await ref.read(settingsMutatorProvider).clearSettings();
                  if (!context.mounted) return;
                  ref.read(localeProvider.notifier).setLocale('en');
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.settingsResetDone)),
                  );
                },
              ),
            ]),
            const SizedBox(height: 32),
            _buildFooter(context),
            const SizedBox(height: 48),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text(l10n.settingsErrorPrefix(e.toString())),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(appSettingsProvider),
              child: Text(l10n.settingsRetry),
            ),
          ],
        ), // Close Column
      ), // Close Center
    );
    if (tabMode) return settingsBody;
    return FloatingDockScaffold(
      appBarContent: SafeArea(
        bottom: false,
        child: Center(
          child: Text(
            AppLocalizations.of(context)!.settingsTitle,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      ),
      currentRoute: RouteNames.settings,
      body: settingsBody,
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title,
      {Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color ?? Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.2,
            ),
      ),
    );
  }

  Widget _buildSettingsGroup(BuildContext context, List<Widget> children) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.42),
        ),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDangerGroup(BuildContext context, List<Widget> children) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.red.withValues(alpha: 0.35),
        ),
      ),
      child: Column(children: children),
    );
  }

  Widget _divider(BuildContext context) {
    return Divider(
      height: 1,
      indent: 56,
      color:
          Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.48),
    );
  }

  String _getLanguageDisplayName(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(localeProvider);
    final l10n = AppLocalizations.of(context)!;
    switch (locale.languageCode) {
      case 'ur':
        return l10n.languageUrdu;
      case 'ru':
        return l10n.languageRussian;
      case 'zh':
        return l10n.languageChinese;
      case 'ja':
        return l10n.languageJapanese;
      case 'fr':
        return l10n.languageFrench;
      case 'ar':
        return l10n.languageArabic;
      case 'es':
        return l10n.languageSpanish;
      case 'de':
        return l10n.languageGerman;
      case 'pt':
        return l10n.languagePortuguese;
      case 'hi':
        return l10n.languageHindi;
      default:
        return l10n.languageEnglish;
    }
  }

  void _showStorageInfo(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Container(
          padding: const EdgeInsets.all(24),
          decoration: _bottomSheetDecoration(context),
          child: Consumer(
            builder: (context, ref, _) {
              final recentFilesAsync = ref.watch(recentFilesProvider);
              return recentFilesAsync.when(
                loading: () => ListView(
                  controller: scrollController,
                  children: [
                    Center(child: _handle(context)),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(l10n.settingsStorageDetails,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 20),
                    Column(
                      children: [
                        SizedBox(
                            height: 140,
                            child: Center(child: CircularProgressIndicator())),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(
                              child: _storageChip(
                                  Icons.picture_as_pdf,
                                  l10n.settingsStoragePdfs,
                                  l10n.settingsCalculating,
                                  Colors.red)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: _storageChip(
                                  Icons.table_chart,
                                  l10n.settingsStorageSheets,
                                  l10n.settingsCalculating,
                                  Colors.green)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: _storageChip(
                                  Icons.description,
                                  l10n.settingsStorageDocs,
                                  l10n.settingsCalculating,
                                  Colors.blue)),
                        ]),
                      ],
                    ),
                  ],
                ),
                error: (error, stack) => ListView(
                  controller: scrollController,
                  children: [
                    Center(child: _handle(context)),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(l10n.settingsStorageDetails,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 20),
                    Center(
                      child: Text(l10n.settingsStorageFailedLoad,
                          style: Theme.of(context).textTheme.bodyMedium),
                    ),
                  ],
                ),
                data: (files) {
                  final stats = _computeCategoryStats(files);
                  return ListView(
                    controller: scrollController,
                    children: [
                      Center(child: _handle(context)),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(l10n.settingsStorageDetails,
                            style: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold)),
                      ),
                      const SizedBox(height: 20),
                      Builder(
                        builder: (context) {
                          final slices = <String, int>{};
                          for (final entry in stats.entries) {
                            slices[_labelForFolder(context, entry.key)] =
                                entry.value['bytes'] ?? 0;
                          }
                          return Column(
                            children: [
                              SizedBox(
                                  height: 140,
                                  child: _storageChartFromMap(context, slices)),
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                    child: _storageChip(
                                        Icons.picture_as_pdf,
                                        l10n.settingsStoragePdfs,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['PDFs']?['bytes'] ?? 0),
                                            stats['PDFs']?['count'] ?? 0),
                                        Colors.red)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: _storageChip(
                                        Icons.table_chart,
                                        l10n.settingsStorageSheets,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Spreadsheets']
                                                        ?['bytes'] ??
                                                    0),
                                            stats['Spreadsheets']?['count'] ??
                                                0),
                                        Colors.green)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: _storageChip(
                                        Icons.description,
                                        l10n.settingsStorageDocs,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Documents']?['bytes'] ??
                                                    0),
                                            stats['Documents']?['count'] ?? 0),
                                        Colors.blue)),
                              ]),
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                    child: _storageChip(
                                        Icons.slideshow,
                                        l10n.settingsStoragePresentations,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Presentations']
                                                        ?['bytes'] ??
                                                    0),
                                            stats['Presentations']?['count'] ??
                                                0),
                                        Colors.orange)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: _storageChip(
                                        Icons.code,
                                        l10n.settingsStorageCode,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Code']?['bytes'] ?? 0),
                                            stats['Code']?['count'] ?? 0),
                                        Colors.purple)),
                                const SizedBox(width: 8),
                                Expanded(
                                    child: _storageChip(
                                        Icons.document_scanner,
                                        l10n.settingsStorageScans,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Scans']?['bytes'] ?? 0),
                                            stats['Scans']?['count'] ?? 0),
                                        Colors.cyan)),
                              ]),
                              const SizedBox(height: 12),
                              Row(children: [
                                Expanded(
                                    child: _storageChip(
                                        Icons.insert_drive_file,
                                        l10n.settingsStorageOther,
                                        l10n.settingsStorageFilesSummary(
                                            StorageService.formatBytes(
                                                stats['Other']?['bytes'] ?? 0),
                                            stats['Other']?['count'] ?? 0),
                                        Colors.teal)),
                              ]),
                            ],
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.lock_outline,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Text(
                                l10n.settingsStoragePrivateFolderInfo,
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.info_outline,
                                size: 20,
                                color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                l10n.settingsStorageDeleteInfo,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _storageChartFromMap(BuildContext context, Map<String, int> slices) {
    final l10n = AppLocalizations.of(context)!;
    final total = slices.values.fold<int>(0, (p, e) => p + e);
    if (total == 0) {
      return Center(
          child: Text(l10n.settingsStorageEmpty,
              style: Theme.of(context).textTheme.bodySmall));
    }

    final sections = <PieChartSectionData>[];
    int idx = 0;
    slices.forEach((label, value) {
      final color = _colorForIndex(idx);
      final percent = value / total * 100;
      sections.add(PieChartSectionData(
        color: color,
        value: value.toDouble(),
        title: '${percent.toStringAsFixed(percent >= 10 ? 0 : 1)}%',
        titleStyle: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
        radius: 45,
        showTitle: percent >= 0.1, // hide extremely tiny labels
        borderSide:
            BorderSide(color: Colors.white.withValues(alpha: 0.08), width: 1),
      ));
      idx++;
    });

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 800),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.scale(
          scale: 0.8 + (0.2 * value),
          child: PieChart(PieChartData(
              sectionsSpace: 2, centerSpaceRadius: 35, sections: sections)),
        ),
      ),
    );
  }

  Color _colorForIndex(int idx) {
    const palette = [
      Colors.red,
      Colors.green,
      Colors.blue,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.grey
    ];
    return palette[idx % palette.length];
  }

  /// Compute category stats from recent files list (Hive data)
  /// Groups files by type and returns {category: {'bytes': X, 'count': Y}}
  Map<String, Map<String, int>> _computeCategoryStats(List<dynamic> files) {
    final stats = <String, Map<String, int>>{
      'PDFs': {'bytes': 0, 'count': 0},
      'Spreadsheets': {'bytes': 0, 'count': 0},
      'Documents': {'bytes': 0, 'count': 0},
      'Presentations': {'bytes': 0, 'count': 0},
      'Code': {'bytes': 0, 'count': 0},
      'Scans': {'bytes': 0, 'count': 0},
      'Other': {'bytes': 0, 'count': 0},
    };

    for (final file in files) {
      if (file.isDeleted) continue;
      final category = _categoryForFileType(file.fileType);
      stats[category]?['bytes'] =
          ((stats[category]?['bytes'] ?? 0) + file.fileSizeBytes).toInt();
      stats[category]?['count'] =
          ((stats[category]?['count'] ?? 0) + 1).toInt();
    }

    return stats;
  }

  String _categoryForFileType(String fileType) {
    switch (fileType.toLowerCase()) {
      case 'pdf':
        return 'PDFs';
      case 'xlsx':
      case 'xls':
      case 'ods':
      case 'csv':
        return 'Spreadsheets';
      case 'docx':
      case 'doc':
      case 'odt':
      case 'rtf':
      case 'txt':
      case 'ott':
      case 'epub':
        return 'Documents';
      case 'ppt':
      case 'pptx':
      case 'odp':
        return 'Presentations';
      case 'java':
      case 'py':
      case 'sh':
      case 'html':
      case 'md':
      case 'log':
      case 'json':
      case 'xml':
        return 'Code';
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
        return 'Scans';
      default:
        return 'Other';
    }
  }

  String _labelForFolder(BuildContext context, String folder) {
    final l10n = AppLocalizations.of(context)!;
    switch (folder) {
      case StorageService.pdfsFolder:
        return l10n.settingsStoragePdfs;
      case StorageService.spreadsheetsFolder:
        return l10n.settingsStorageSheets;
      case StorageService.documentsFolder:
        return l10n.settingsStorageDocs;
      case StorageService.codeFolder:
        return l10n.settingsStorageCode;
      case StorageService.presentationsFolder:
        return l10n.settingsStoragePresentations;
      case StorageService.imagesFolder:
        return l10n.settingsStorageImages;
      case StorageService.scansFolder:
        return l10n.settingsStorageScans;
      case StorageService.trashFolder:
        return l10n.settingsTrash;
      default:
        return folder;
    }
  }

  Widget _storageChip(IconData icon, String label, String size, Color color) =>
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10)),
        child: Column(children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600, color: color),
          ),
          Text(
            size,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 10, color: color.withValues(alpha: 0.7)),
          ),
        ]),
      );

  Widget _buildOnboardingReplayRow(
      BuildContext context, WidgetRef ref, bool show) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color:
                      colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  Icons.auto_stories_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.settingsReplayOnboarding,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    Text(
                      l10n.settingsReplayOnboardingDesc,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                child: Switch(
                  value: show,
                  onChanged: (value) {
                    ref
                        .read(settingsMutatorProvider)
                        .updateShowOnboardingNextLaunch(value);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showLanguagePicker(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final currentCode = ref.read(localeProvider).languageCode;

    void pickLang(String code) {
      ref.read(localeProvider.notifier).setLocale(code);
      ref.read(settingsMutatorProvider).updateLanguage(code);
      Navigator.pop(context);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: _bottomSheetDecoration(context),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _handle(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  l10n.settingsSelectLanguage,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: ConnectedSheetGroup(
                    children: [
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇬🇧',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageEnglish,
                        detail: const Text('English'),
                        trailing: Icon(
                          currentCode == 'en'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'en'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('en'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇵🇰',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageUrdu,
                        detail: const Text('Urdu'),
                        trailing: Icon(
                          currentCode == 'ur'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'ur'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('ur'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇸🇦',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageArabic,
                        detail: const Text('Arabic'),
                        trailing: Icon(
                          currentCode == 'ar'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'ar'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('ar'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇨🇳',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageChinese,
                        detail: const Text('Chinese'),
                        trailing: Icon(
                          currentCode == 'zh'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'zh'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('zh'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇫🇷',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageFrench,
                        detail: const Text('French'),
                        trailing: Icon(
                          currentCode == 'fr'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'fr'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('fr'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇩🇪',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageGerman,
                        detail: const Text('German'),
                        trailing: Icon(
                          currentCode == 'de'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'de'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('de'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇮🇳',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageHindi,
                        detail: const Text('Hindi'),
                        trailing: Icon(
                          currentCode == 'hi'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'hi'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('hi'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇯🇵',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageJapanese,
                        detail: const Text('Japanese'),
                        trailing: Icon(
                          currentCode == 'ja'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'ja'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('ja'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇧🇷',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languagePortuguese,
                        detail: const Text('Portuguese'),
                        trailing: Icon(
                          currentCode == 'pt'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'pt'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('pt'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇷🇺',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageRussian,
                        detail: const Text('Russian'),
                        trailing: Icon(
                          currentCode == 'ru'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'ru'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('ru'),
                      ),
                      ConnectedSheetRow(
                        leading: SheetIconChip.emoji(
                          emoji: '🇪🇸',
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHigh
                              .withValues(alpha: 0.9),
                        ),
                        title: l10n.languageSpanish,
                        detail: const Text('Spanish'),
                        trailing: Icon(
                          currentCode == 'es'
                              ? Icons.check_circle
                              : Icons.circle_outlined,
                          color: currentCode == 'es'
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outline,
                        ),
                        onTap: () => pickLang('es'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _bottomSheetDecoration(BuildContext context) {
    return BoxDecoration(
      gradient: LinearGradient(
        colors: [
          Theme.of(context).colorScheme.surface,
          Theme.of(context).colorScheme.surface.withValues(alpha: 0.95),
        ],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ),
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
    );
  }

  Widget _handle(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  void _showVersionInfo(BuildContext context, PackageInfo packageInfo) {
    final l10n = AppLocalizations.of(context)!;
    final appName = packageInfo.appName;
    final version = packageInfo.version;
    final buildNumber = packageInfo.buildNumber;
    final packageName = packageInfo.packageName;
    final versionString = l10n.settingsVersionWithBuild(version, buildNumber);
    const iconAsset = 'assets/air_docs_emblem.png';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.3),
                    blurRadius: 15,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  iconAsset,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              appName,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                versionString,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              packageName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(
                    text: l10n.settingsVersionClipboardInfo(
                      appName,
                      version,
                      buildNumber,
                      packageName,
                    ),
                  ));
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.settingsCopiedInfo)),
                  );
                },
                icon: const Icon(Icons.copy),
                label: Text(l10n.settingsCopyInfo),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPrivacyPolicy(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (context, scrollController) => Container(
          decoration: _bottomSheetDecoration(context),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(24),
            children: [
              Center(child: _handle(context)),
              const SizedBox(height: 16),
              Center(
                child: Icon(
                  Icons.shield,
                  size: 48,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  l10n.settingsPrivacyPolicy,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
              ),
              const SizedBox(height: 24),
              _policyItem(
                context,
                Icons.wifi_off,
                l10n.settingsPrivacyOffline,
                l10n.settingsPrivacyOfflineDesc,
              ),
              _policyItem(
                context,
                Icons.storage,
                l10n.settingsPrivacyLocalStorage,
                l10n.settingsPrivacyLocalStorageDesc,
              ),
              _policyItem(
                context,
                Icons.psychology,
                l10n.settingsPrivacyOnDevice,
                l10n.settingsPrivacyOnDeviceDesc,
              ),
              _policyItem(
                context,
                Icons.block,
                l10n.settingsPrivacyNoAds,
                l10n.settingsPrivacyNoAdsDesc,
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  l10n.settingsPrivacyByDesign,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.settingsPrivacyTransparency,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(
        l10n.settingsCopyright,
        textAlign: TextAlign.center,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _policyItem(
      BuildContext context, IconData icon, String title, String desc) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon,
                color: Theme.of(context).colorScheme.primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class AnimatedListView extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets padding;

  const AnimatedListView({
    super.key,
    required this.children,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: padding,
      children: children,
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback? onTap;

  const _SettingsRow({
    required this.icon,
    required this.title,
    this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color:
                      colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 20,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (value != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        value!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DangerRow extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String confirmText;
  final FutureOr<void> Function() onConfirm;

  const _DangerRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.confirmText,
    required this.onConfirm,
  });

  @override
  State<_DangerRow> createState() => _DangerRowState();
}

class _DangerRowState extends State<_DangerRow> {
  final _controller = TextEditingController();
  bool _confirmed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _showDangerDialog(context),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color:
                      colorScheme.surfaceContainerHigh.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(widget.icon, size: 20, color: Colors.red),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: Colors.red,
                          ),
                    ),
                    Text(
                      widget.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDangerDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // If confirmText is empty, just directly navigate (like Trash)
    if (widget.confirmText.isEmpty) {
      unawaited(Future.sync(widget.onConfirm));
      return;
    }

    _controller.clear();
    _confirmed = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, dialogSetState) {
          return AlertDialog(
            title: Text(widget.title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.subtitle),
                const SizedBox(height: 16),
                Text(l10n.settingsTypeToConfirm(widget.confirmText)),
                const SizedBox(height: 12),
                TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: widget.confirmText,
                  ),
                  onChanged: (v) => dialogSetState(() => _confirmed =
                      v.trim().toUpperCase() == widget.confirmText),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(l10n.cancel),
              ),
              FilledButton(
                onPressed: _confirmed
                    ? () => unawaited(Future.sync(widget.onConfirm))
                    : null,
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                child: Text(l10n.confirm),
              ),
            ],
          );
        },
      ),
    );
  }
}
