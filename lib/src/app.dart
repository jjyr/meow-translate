import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'jobs/job_controller.dart';
import 'l10n/app_localizations.dart';
import 'ui/root_window.dart';

final class MeowApp extends StatelessWidget {
  const MeowApp({required this.controller, super.key});

  final JobController controller;

  @override
  Widget build(BuildContext context) {
    return MacosApp(
      title: 'Meow',
      debugShowCheckedModeBanner: false,
      theme: MacosThemeData.light(),
      darkTheme: MacosThemeData.dark(),
      themeMode: ThemeMode.system,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      localeResolutionCallback: (locale, supported) {
        if (locale == null) return const Locale('en');
        for (final candidate in supported) {
          if (candidate.languageCode == locale.languageCode) {
            if (locale.languageCode != 'zh' ||
                candidate.scriptCode == locale.scriptCode) {
              return candidate;
            }
          }
        }
        if (locale.languageCode == 'zh') {
          final traditional = const {
            'TW',
            'HK',
            'MO',
          }.contains(locale.countryCode);
          return Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: traditional ? 'Hant' : 'Hans',
          );
        }
        return const Locale('en');
      },
      home: RootWindow(controller: controller),
    );
  }
}
