import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'package:air_docs_viewer/core/presentation/widgets/connected_sheet_group.dart';
import 'package:air_docs_viewer/features/settings/domain/entities/app_settings.dart';
import 'package:flutter/material.dart';

/// Callbacks for file action bottom sheet. Null callbacks hide their row.
class FileActionCallbacks {
  final VoidCallback? onRename;
  final VoidCallback? onDuplicate;
  final VoidCallback? onExport;
  final VoidCallback? onFileInfo;
  final VoidCallback? onDelete;
  final VoidCallback? onCopyText;

  const FileActionCallbacks({
    this.onRename,
    this.onDuplicate,
    this.onExport,
    this.onFileInfo,
    this.onDelete,
    this.onCopyText,
  });
}

/// Shows a styled file-action bottom sheet with the given callbacks.
/// Rows with null callbacks are automatically hidden.
void showFileActionBottomSheet({
  required BuildContext context,
  required RecentFile file,
  required FileActionCallbacks callbacks,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (_, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerLowest
              .withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.98
                      : 0.94),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .outlineVariant
                .withValues(alpha: 0.22),
          ),
        ),
        child: SingleChildScrollView(
          controller: scrollController,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    Text(
                      file.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppLocalizations.of(context)!.fileActionSubtitle,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if ([
                callbacks.onRename,
                callbacks.onDuplicate,
                callbacks.onExport,
                callbacks.onCopyText,
                callbacks.onFileInfo
              ].any((callback) => callback != null))
                ConnectedSheetGroup(
                  children: [
                    if (callbacks.onRename != null)
                      _buildActionRow(
                        context: ctx,
                        icon: Icons.edit_outlined,
                        title: AppLocalizations.of(ctx)!.fileActionRename,
                        iconColor: Theme.of(context).colorScheme.primary,
                        subtitle:
                            AppLocalizations.of(ctx)!.fileActionRenameDesc,
                        onTap: callbacks.onRename!,
                      ),
                    if (callbacks.onDuplicate != null)
                      _buildActionRow(
                        context: ctx,
                        icon: Icons.content_copy,
                        title: AppLocalizations.of(ctx)!.fileActionDuplicate,
                        iconColor: Colors.blue,
                        subtitle:
                            AppLocalizations.of(ctx)!.fileActionDuplicateDesc,
                        onTap: callbacks.onDuplicate!,
                      ),
                    if (callbacks.onExport != null)
                      _buildActionRow(
                        context: ctx,
                        icon: Icons.save_alt,
                        title: AppLocalizations.of(ctx)!.fileActionExport,
                        iconColor: Colors.green,
                        subtitle:
                            AppLocalizations.of(ctx)!.fileActionExportDesc,
                        showChevron: true,
                        onTap: callbacks.onExport!,
                      ),
                    if (callbacks.onCopyText != null)
                      _buildActionRow(
                        context: ctx,
                        icon: Icons.content_paste,
                        title: AppLocalizations.of(ctx)!.fileActionCopyText,
                        iconColor: Colors.teal,
                        subtitle:
                            AppLocalizations.of(ctx)!.fileActionCopyTextDesc,
                        onTap: callbacks.onCopyText!,
                      ),
                    if (callbacks.onFileInfo != null)
                      _buildActionRow(
                        context: ctx,
                        icon: Icons.info_outline,
                        title: AppLocalizations.of(ctx)!.fileActionFileInfo,
                        iconColor: Colors.grey,
                        onTap: callbacks.onFileInfo!,
                      ),
                  ],
                ),
              if (callbacks.onDelete != null) ...[
                const SizedBox(height: 8),
                ConnectedSheetGroup(
                  children: [
                    _buildActionRow(
                      context: ctx,
                      icon: Icons.delete_outline,
                      title: AppLocalizations.of(ctx)!.delete,
                      iconColor: Colors.red,
                      titleColor: Colors.red,
                      onTap: callbacks.onDelete!,
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    ),
  );
}

Widget _buildActionRow({
  required BuildContext context,
  required IconData icon,
  required String title,
  required Color iconColor,
  String? subtitle,
  bool showChevron = false,
  Color? titleColor,
  required VoidCallback onTap,
}) {
  return Padding(
    padding: EdgeInsets.zero,
    child: ConnectedSheetRow(
      leading: SheetIconChip.icon(
        icon: icon,
        color: iconColor,
        backgroundColor: Theme.of(context)
            .colorScheme
            .surfaceContainerHigh
            .withValues(alpha: 0.9),
      ),
      title: title,
      detail: subtitle == null ? null : Text(subtitle),
      titleColor: titleColor,
      detailColor: Theme.of(context).colorScheme.onSurfaceVariant,
      trailing: showChevron
          ? Icon(Icons.chevron_right,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant)
          : null,
      onTap: () {
        Navigator.pop(context);
        onTap();
      },
    ),
  );
}
