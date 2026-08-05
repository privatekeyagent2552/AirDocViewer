import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/settings_providers.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen>
    with TickerProviderStateMixin {
  late final AnimationController _iconController;
  late final Animation<double> _iconScale;
  late final Animation<double> _titleFade;
  late final Animation<Offset> _titleSlide;

  bool _exiting = false;
  late final AnimationController _exitController;
  late final Animation<double> _exitScale;
  late final Animation<double> _exitFade;

  @override
  void initState() {
    super.initState();

    _iconController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
    _iconScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _iconController, curve: Curves.easeOutBack),
    );
    _titleFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _iconController,
        curve: const Interval(0.3, 0.85, curve: Curves.easeOut),
      ),
    );
    _titleSlide = Tween<Offset>(
      begin: const Offset(0, 0.12),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _iconController,
        curve: const Interval(0.3, 0.85, curve: Curves.easeOutCubic),
      ),
    );

    _exitController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _exitScale = Tween<double>(begin: 1.0, end: 1.05).animate(
      CurvedAnimation(
        parent: _exitController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeOut),
      ),
    );
    _exitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _exitController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeIn),
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_exiting) {
        _iconController.forward();
      }
    });
  }

  @override
  void dispose() {
    _iconController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_exiting) return;
    setState(() => _exiting = true);

    final mutator = ref.read(settingsMutatorProvider);
    await mutator.completeOnboarding();

    _exitController.forward().then((_) {
      if (mounted) context.go(RouteNames.home);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return AnimatedBuilder(
      animation: Listenable.merge([_exitScale, _exitFade]),
      builder: (context, child) => Opacity(
        opacity: _exitFade.value,
        child: Transform.scale(scale: _exitScale.value, child: child),
      ),
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      AnimatedBuilder(
                        animation: _iconScale,
                        builder: (context, _) => Transform.scale(
                          scale: _iconScale.value,
                          child: Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12),
                              border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withValues(alpha: 0.22),
                                width: 1.5,
                              ),
                            ),
                            child: Icon(
                              Icons.auto_awesome_rounded,
                              size: 42,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      AnimatedBuilder(
                        animation:
                            Listenable.merge([_titleFade, _titleSlide]),
                        builder: (context, _) => Opacity(
                          opacity: _titleFade.value,
                          child: SlideTransition(
                            position: _titleSlide,
                            child: Column(
                              children: [
                                Text(
                                  l10n.onboardingSlide1Title,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  l10n.onboardingSlide1Tagline,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _finish,
                    child: Text(l10n.onboardingGetStarted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
