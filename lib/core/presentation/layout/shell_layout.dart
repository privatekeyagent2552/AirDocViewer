import 'package:flutter/material.dart';

/// Shared inset calculations for [FloatingDockScaffold] overlays.
/// Keeps scroll content clear of the app bar, footer, and bottom dock on all devices.
class ShellLayout {
  ShellLayout._();

  /// Height of the bar content row below the status bar.
  static const double appBarContentHeight = 48;

  /// Dock pill inner height (vertical padding + icon row + label space).
  static const double dockBarHeight = 84;

  /// Dock outer padding below the safe area.
  static const double dockBottomPadding = 8;

  /// Gap between the dock pill and the developer footer under it.
  static const double footerGapBelowDock = 2;

  /// Space reserved for the developer footer below the dock pill.
  static const double footerBandHeight = 28;

  /// Keep geometry in sync with [MyApp]'s TextScaler clamp (1.1–1.45).
  static double _clampedScale(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    return scale.clamp(1.1, 1.45).toDouble();
  }

  /// Narrow phone breakpoint used for stacking dense action rows.
  static const double narrowWidth = 360;

  static double topContentInset(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return top + appBarContentHeight * _clampedScale(context);
  }

  static double bottomContentInset(
    BuildContext context, {
    bool includeFooter = true,
  }) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final footer = includeFooter ? footerBandHeight + footerGapBelowDock : 0.0;
    return bottom + dockBarHeight + dockBottomPadding + footer;
  }

  static EdgeInsets contentPadding(
    BuildContext context, {
    bool includeFooter = true,
  }) {
    return EdgeInsets.only(
      top: topContentInset(context),
      bottom: bottomContentInset(context, includeFooter: includeFooter),
    );
  }

  static double overlayTopHeight(BuildContext context) {
    return MediaQuery.paddingOf(context).top + appBarContentHeight;
  }

  static double overlayBottomHeight(BuildContext context, {bool includeFooter = true}) {
    final footer = includeFooter ? footerBandHeight + footerGapBelowDock : 0.0;
    return MediaQuery.paddingOf(context).bottom +
        dockBarHeight +
        dockBottomPadding +
        footer;
  }
}
