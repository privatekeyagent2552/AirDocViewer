import 'package:flutter/material.dart';
import 'package:air_docs_viewer/core/presentation/constants.dart';

/// Fixed branded credit under the Home / Library dock (not in scroll lists).
class DeveloperFooter extends StatelessWidget {
  const DeveloperFooter({super.key, this.padding});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding:
          padding ?? const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Text(
        'Developed by $kDeveloperName',
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}
