import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:air_docs_viewer/core/presentation/widgets/floating_dock_scaffold.dart';
import 'package:air_docs_viewer/core/presentation/widgets/developer_footer.dart';
import 'package:air_docs_viewer/features/home/presentation/screens/home_screen.dart';
import 'package:air_docs_viewer/features/home/presentation/screens/documents_screen.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';

/// Main shell — Home + Library tabs focused on document viewing only.
class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell> {
  int _currentPage = 0;

  DateTime? _lastBackPress;
  static const Duration _backPressExitDuration = Duration(seconds: 2);

  bool _libraryIsSearching = false;
  final _librarySearchController = TextEditingController();

  void _switchToPage(int page) {
    if (page == _currentPage || page < 0 || page > 1) return;
    setState(() => _currentPage = page);
  }

  @override
  void dispose() {
    _librarySearchController.dispose();
    super.dispose();
  }

  Widget _buildBrandHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Center(
        child: Image.asset(
          'assets/air_docs_logo.png',
          height: 48,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }

  Widget _buildHomeAppBar(BuildContext context) => _buildBrandHeader(context);

  Widget _buildLibraryAppBar(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          if (!_libraryIsSearching)
            Expanded(
              child: Text(
                AppLocalizations.of(context)!.navLibrary,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.arrow_back, size: 20),
              onPressed: () {
                _librarySearchController.clear();
                ref.read(librarySearchProvider.notifier).clear();
                setState(() => _libraryIsSearching = false);
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          if (_libraryIsSearching) ...[
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                key: const ValueKey('search'),
                controller: _librarySearchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context)!.librarySearchHint,
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (v) {
                  ref.read(librarySearchProvider.notifier).update(v);
                },
              ),
            ),
          ],
          IconButton(
            icon: Icon(
              _libraryIsSearching ? Icons.clear : Icons.search,
              size: 20,
            ),
            onPressed: () {
              if (_libraryIsSearching) {
                _librarySearchController.clear();
                ref.read(librarySearchProvider.notifier).clear();
                setState(() => _libraryIsSearching = false);
              } else {
                setState(() => _libraryIsSearching = true);
              }
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBarForPage(int page) {
    switch (page) {
      case 1:
        return KeyedSubtree(
          key: const ValueKey(1),
          child: _buildLibraryAppBar(context),
        );
      default:
        return KeyedSubtree(
          key: const ValueKey(0),
          child: _buildHomeAppBar(context),
        );
    }
  }

  Widget _buildTabBody() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: (details) {
            if (details.primaryVelocity == null) return;
            final isRTL = Directionality.of(context) == TextDirection.rtl;
            final velocity =
                isRTL ? -details.primaryVelocity! : details.primaryVelocity!;
            if (velocity < -300 && _currentPage < 1) {
              _switchToPage(_currentPage + 1);
            } else if (velocity > 300 && _currentPage > 0) {
              _switchToPage(_currentPage - 1);
            }
          },
          child: RepaintBoundary(
            child: SizedBox(
              width: constraints.maxWidth,
              height: constraints.maxHeight,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: switch (_currentPage) {
                  0 => HomeScreen(
                        key: const ValueKey(0),
                        tabMode: true,
                        onSeeAll: () => _switchToPage(1),
                      ),
                  _ => DocumentsScreen(key: const ValueKey(1), tabMode: true),
                },
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
      child: FloatingDockScaffold(
        currentRoute: RouteNames.home,
        activeTabIndex: _currentPage,
        onTabChanged: _switchToPage,
        tabCount: 2,
        footerContent: const DeveloperFooter(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
        ),
        appBarContent: _currentPage == 0
            ? null
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _buildAppBarForPage(_currentPage),
              ),
        body: _buildTabBody(),
      ),
    );
  }
}
