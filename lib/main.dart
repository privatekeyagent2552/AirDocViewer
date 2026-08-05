import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:air_docs_viewer/config/routing/app_router.dart';
import 'package:air_docs_viewer/config/theme/app_theme.dart';
import 'package:logger/logger.dart';
import 'package:air_docs_viewer/features/settings/data/datasources/hive_datasource.dart';
import 'package:air_docs_viewer/features/settings/presentation/providers/locale_provider.dart';
import 'package:air_docs_viewer/services/file_intent_service.dart';
import 'package:air_docs_viewer/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'dart:async';

final log = Logger();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  String savedLanguage = 'en';
  bool onboardingSeen = true;
  bool reShowOnboarding = false;

  try {
    final settings = await HiveDatasource.initialize();
    if (settings?.language != null) {
      savedLanguage = settings!.language;
      log.i('Language loaded from Hive: $savedLanguage');
    }
    onboardingSeen = settings?.hasDismissedWelcome ?? false;
    reShowOnboarding = settings?.showOnboardingNextLaunch ?? false;
  } catch (e) {
    log.w('Could not initialize Hive, using defaults: $e');
  }

  if (!onboardingSeen || reShowOnboarding) {
    setInitialRoute(RouteNames.onboarding);
    log.i(
        'Showing onboarding (firstLaunch: ${!onboardingSeen}, reShow: $reShowOnboarding)');
  }

  // Light-only app: system chrome matches light theme.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        initialLocaleProvider.overrideWithValue(savedLanguage),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> {
  StreamSubscription<String>? _fileIntentSub;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = createGoRouter();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fileIntentSub = FileIntentService.fileIntentStream.listen((filePath) {
        if (!mounted) return;
        final encodedPath = Uri.encodeComponent(filePath);
        final fileName = filePath.split('/').last;
        log.i('File intent: navigating to viewer: $fileName');
        _router.push('/viewer?path=$encodedPath&name=$fileName');
      }, onError: (e) => log.e('File intent error: $e'));

      FileIntentService.initialize();
    });
  }

  @override
  void dispose() {
    _fileIntentSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final locale = ref.watch(localeProvider);

    return MaterialApp.router(
      title: 'Air Docs Viewer',
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        // Bump in-app text; keep a higher floor so UI labels stay readable.
        final scaled = mq.textScaler.scale(1.0) * 1.15;
        return MediaQuery(
          data: mq.copyWith(
            textScaler: TextScaler.linear(scaled.clamp(1.1, 1.45)),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.lightTheme,
      themeMode: ThemeMode.light,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: _router,
    );
  }
}
