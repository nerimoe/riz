import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'providers/app_controller.dart';
import 'ui/riz_home.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  runApp(const ProviderScope(child: RizApp()));
}

class RizApp extends ConsumerWidget {
  const RizApp({super.key});

  static final _router = GoRouter(
    routes: [GoRoute(path: '/', builder: (context, state) => const RizHome())],
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appControllerProvider.select((s) => s.settings));
    return DynamicColorBuilder(
      builder: (light, dark) {
        const seed = Color(0xFF006B58);
        ThemeData theme(Brightness brightness, ColorScheme? dynamic) {
          final scheme =
              dynamic ??
              ColorScheme.fromSeed(
                seedColor: seed,
                brightness: brightness,
                dynamicSchemeVariant: DynamicSchemeVariant.neutral,
              );
          return ThemeData(
            useMaterial3: true,
            brightness: brightness,
            colorScheme: scheme,
            scaffoldBackgroundColor: scheme.surface,
            cardTheme: const CardThemeData(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
            ),
            inputDecorationTheme: const InputDecorationTheme(
              border: OutlineInputBorder(),
              filled: true,
            ),
            visualDensity: VisualDensity.standard,
          );
        }

        return MaterialApp.router(
          title: 'Riz',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light, light),
          darkTheme: theme(Brightness.dark, dark),
          themeMode: settings.themeMode,
          locale: settings.locale,
          supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: _router,
        );
      },
    );
  }
}

extension BuildContextX on BuildContext {
  ThemeData get theme => Theme.of(this);
  ColorScheme get colors => theme.colorScheme;
  TextTheme get text => theme.textTheme;
  bool get isCompact => MediaQuery.sizeOf(this).width < 600;
  bool get isExpanded => MediaQuery.sizeOf(this).width >= 840;
  bool get isWide => MediaQuery.sizeOf(this).width >= 1200;
}
