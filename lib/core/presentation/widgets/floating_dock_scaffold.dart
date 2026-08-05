import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/core/presentation/layout/shell_layout.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// Floating overlay scaffold that places app bar and bottom dock as transparent
/// overlays, allowing content to scroll behind them like iOS/macOS style.
class FloatingDockScaffold extends StatefulWidget {
  final Widget body;
  final String currentRoute;
  final bool showBottomDock;
  final Widget? appBarContent;
  final Widget? floatingActionButton;
  final Widget? footerContent;

  /// When set, dock navigates pages instead of GoRouter routes.
  final int? activeTabIndex;
  final ValueChanged<int>? onTabChanged;

  /// Number of tabs shown in the bottom dock (2 = Home + Library only).
  final int tabCount;

  const FloatingDockScaffold({
    super.key,
    required this.body,
    required this.currentRoute,
    this.showBottomDock = true,
    this.appBarContent,
    this.floatingActionButton,
    this.footerContent,
    this.activeTabIndex,
    this.onTabChanged,
    this.tabCount = 3,
  });

  @override
  State<FloatingDockScaffold> createState() => _FloatingDockScaffoldState();
}

class _FloatingDockScaffoldState extends State<FloatingDockScaffold> {
  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomSafePadding = mediaQuery.padding.bottom;
    final dockHeight = widget.showBottomDock
        ? ShellLayout.dockBarHeight +
            ShellLayout.dockBottomPadding +
            (widget.footerContent != null
                ? ShellLayout.footerBandHeight + ShellLayout.footerGapBelowDock
                : 0.0)
        : 0.0;

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final statusBarStyle = SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: statusBarStyle,
      child: Scaffold(
        backgroundColor: Theme.of(context).colorScheme.surface,
        body: Stack(
          children: [
            // Main scrollable content - FULL SCREEN, scrolls behind overlays
            Positioned.fill(
              child: widget.body,
            ),

            // Floating top bar with blur (overlay on top)
            if (widget.appBarContent != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: ShellLayout.overlayTopHeight(context),
                child: _FloatingAppBar(
                  content: widget.appBarContent!,
                ),
              ),

            // Fading gradient at the bottom to obscure content scrolling under the dock
            // This creates the "white type shadow" in light mode and "dark shadow" in dark mode
            if (widget.showBottomDock)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: dockHeight + bottomSafePadding + 12,
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Theme.of(context).colorScheme.surface.withValues(alpha: 0),
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.7),
                          Theme.of(context)
                              .colorScheme
                              .surface
                              .withValues(alpha: 0.95),
                          Theme.of(context).colorScheme.surface,
                        ],
                        stops: const [0.0, 0.35, 0.75, 1.0],
                      ),
                    ),
                  ),
                ),
              ),

            // Floating bottom dock + optional developer credit under the pill
            if (widget.showBottomDock)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: RepaintBoundary(
                  child: _FloatingDock(
                    bottomPadding: bottomSafePadding,
                    currentRoute: widget.currentRoute,
                    activeTabIndex: widget.activeTabIndex,
                    onTabChanged: widget.onTabChanged,
                    tabCount: widget.tabCount,
                    footer: widget.footerContent,
                  ),
                ),
              ),

            // Floating action button - above the dock
            if (widget.floatingActionButton != null && widget.showBottomDock)
              Positioned(
                right: 16,
                bottom: dockHeight + bottomSafePadding + 8,
                child: widget.floatingActionButton!,
              ),
          ],
        ),
      ),
    );
  }
}

/// Floating app bar with blur background
class _FloatingAppBar extends StatelessWidget {
  final Widget content;

  const _FloatingAppBar({
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Stack(
      children: [
        // Shadow below the top bar
        Positioned(
          bottom: -8,
          left: 0,
          right: 0,
          height: 8,
          child: Container(
            decoration: BoxDecoration(
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withValues(alpha: 0.3)
                      : Colors.black.withValues(alpha: 0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
          ),
        ),
        // Main app bar with rounded bottom corners - FULL WIDTH
        ClipRRect(
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(16),
            bottomRight: Radius.circular(16),
          ),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.95)
                    : Theme.of(context)
                        .colorScheme
                        .surface
                        .withValues(alpha: 0.92),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outline
                        .withValues(alpha: 0.2),
                    width: 1,
                  ),
                ),
              ),
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: ShellLayout.appBarContentHeight,
                  child: Center(child: content),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Floating bottom dock with blur background and simple bottom shadow
class _FloatingDock extends StatelessWidget {
  final double bottomPadding;
  final String currentRoute;
  final int? activeTabIndex;
  final ValueChanged<int>? onTabChanged;
  final int tabCount;
  final Widget? footer;

  const _FloatingDock({
    required this.bottomPadding,
    required this.currentRoute,
    this.activeTabIndex,
    this.onTabChanged,
    this.tabCount = 3,
    this.footer,
  });

  bool _isActive(int tabIndex) {
    if (activeTabIndex != null) return activeTabIndex == tabIndex;
    switch (tabIndex) {
      case 0: return currentRoute == RouteNames.home;
      case 1: return currentRoute == RouteNames.documents;
      case 2: return currentRoute == RouteNames.settings;
      default: return false;
    }
  }

  void _onTap(int tabIndex, BuildContext context) {
    if (onTabChanged != null) {
      if (activeTabIndex != tabIndex) onTabChanged!(tabIndex);
    } else {
      switch (tabIndex) {
        case 0:
          if (currentRoute != RouteNames.home) context.go(RouteNames.home);
        case 1:
          if (currentRoute != RouteNames.documents) {
            context.push(RouteNames.documents);
          }
        case 2:
          if (currentRoute != RouteNames.settings) {
            context.push(RouteNames.settings);
          }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: isDark
                        ? Colors.black.withValues(alpha: 0.45)
                        : Colors.black.withValues(alpha: 0.12),
                    blurRadius: 24,
                    spreadRadius: -2,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surface
                          .withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Theme.of(context)
                            .colorScheme
                            .outline
                            .withValues(alpha: 0.2),
                        width: 1,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 10, horizontal: 14),
                      child: SizedBox(
                        height: 64,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          mainAxisSize: MainAxisSize.max,
                          children: [
                            Expanded(
                              child: _DockItem(
                                icon: Icons.home,
                                label: AppLocalizations.of(context)!.navHome,
                                isActive: _isActive(0),
                                onTap: () => _onTap(0, context),
                              ),
                            ),
                            Expanded(
                              child: _DockItem(
                                icon: Icons.auto_stories,
                                label: AppLocalizations.of(context)!.navLibrary,
                                isActive: _isActive(1),
                                onTap: () => _onTap(1, context),
                              ),
                            ),
                            if (tabCount > 2)
                              Expanded(
                                child: _DockItem(
                                  icon: Icons.settings,
                                  label:
                                      AppLocalizations.of(context)!.navSettings,
                                  isActive: _isActive(2),
                                  onTap: () => _onTap(2, context),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (footer != null) ...[
              SizedBox(height: ShellLayout.footerGapBelowDock),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Stateful dock item that manages its own animation state
class _DockItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _DockItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_DockItem> createState() => _DockItemState();
}

class _DockItemState extends State<_DockItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
      value: widget.isActive ? 1.0 : 0.0,
    );

    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void didUpdateWidget(_DockItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        _controller.forward(from: 0.0);
      } else {
        _controller.reverse(from: 1.0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(16),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 300),
            alignment: Alignment.topCenter,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Icon - always visible with opacity animation
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: widget.isActive ? 1.0 : 0.55,
                      duration: const Duration(milliseconds: 300),
                      child: Icon(
                        widget.icon,
                        size: 28,
                        color: widget.isActive
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                // Label - only rendered when active, fades in/out
                if (widget.isActive) ...[
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 18,
                    child: FadeTransition(
                      opacity: _fadeAnimation,
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              fontSize: 12,
                              color: Theme.of(context)
                                  .colorScheme
                                  .secondary,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
