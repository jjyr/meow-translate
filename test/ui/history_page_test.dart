import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:meow_translate/src/jobs/job_controller.dart';
import 'package:meow_translate/src/jobs/job_repository.dart';
import 'package:meow_translate/src/jobs/translation_job.dart';
import 'package:meow_translate/src/l10n/app_localizations.dart';
import 'package:meow_translate/src/platform/desktop_services.dart';
import 'package:meow_translate/src/settings/app_settings.dart';
import 'package:meow_translate/src/settings/settings_repository.dart';
import 'package:meow_translate/src/storage/app_paths.dart';
import 'package:meow_translate/src/ui/history_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('job actions wrap without overflowing a narrow window', (
    tester,
  ) async {
    final temporaryDirectory = Directory.systemTemp.createTempSync(
      'meow-history-page-test-',
    );
    addTearDown(() {
      if (temporaryDirectory.existsSync()) {
        temporaryDirectory.deleteSync(recursive: true);
      }
    });
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(480, 640);

    final paths = AppPaths(
      supportDirectory: Directory('${temporaryDirectory.path}/support'),
      cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
    );
    final controller = JobController(
      paths: paths,
      settingsRepository: SettingsRepository(paths),
      jobRepository: JobRepository(paths),
      desktopServices: DesktopServices(),
    );
    controller.jobs = [
      TranslationJob(
        id: 'job-1',
        sourcePath:
            '/books/a-very-long-book-title-that-still-needs-attention.epub',
        sourceBookmark: '/books/book.epub',
        outputDirectory: temporaryDirectory.path,
        outputDirectoryBookmark: temporaryDirectory.path,
        targetLanguage: 'Русский язык с длинным названием',
        keepOriginal: true,
        preserveSourceFormat: false,
        provider: TranslationProvider.openAiCompatible,
        createdAt: DateTime.utc(2026),
        status: TranslationJobStatus.waitingForAction,
        totalUnits: 0,
        completedUnitIds: const {},
        failedUnitIds: const {'unit-2'},
        errorMessage: 'The translation engine needs attention.',
      ),
    ];

    await tester.pumpWidget(
      MacosApp(
        locale: const Locale('ru'),
        theme: MacosThemeData.light(),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: HistoryPage(controller: controller),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 1));

    expect(tester.takeException(), isNull);
    final buttons = find.byType(PushButton);
    expect(buttons, findsNWidgets(4));
    final buttonRows = <double>{
      for (final element in buttons.evaluate())
        tester.getTopLeft(find.byWidget(element.widget)).dy,
    };
    expect(buttonRows.length, greaterThan(1));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
