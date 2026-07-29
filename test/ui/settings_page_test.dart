import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:macos_ui/macos_ui.dart';
import 'package:meow_translate/src/ebook/calibre_service.dart';
import 'package:meow_translate/src/jobs/job_controller.dart';
import 'package:meow_translate/src/jobs/job_repository.dart';
import 'package:meow_translate/src/l10n/app_localizations.dart';
import 'package:meow_translate/src/platform/desktop_services.dart';
import 'package:meow_translate/src/settings/settings_repository.dart';
import 'package:meow_translate/src/storage/app_paths.dart';
import 'package:meow_translate/src/ui/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Calibre detection uses the draft path and refreshes install help',
    (tester) async {
      final temporaryDirectory = Directory.systemTemp.createTempSync(
        'meow-settings-page-test-',
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
      tester.view.physicalSize = const Size(900, 1100);

      final paths = AppPaths(
        supportDirectory: Directory('${temporaryDirectory.path}/support'),
        cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
      );
      final converter = _RecordingBookConverter();
      final controller = JobController(
        paths: paths,
        settingsRepository: SettingsRepository(paths),
        jobRepository: JobRepository(paths),
        desktopServices: DesktopServices(),
        bookConverter: converter,
      );
      controller.calibreInstallation = const CalibreInstallation(
        executable: '/saved/ebook-convert',
        version: 'calibre saved',
      );

      await tester.pumpWidget(
        MacosApp(
          locale: const Locale('en'),
          theme: MacosThemeData.light(),
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: SettingsPage(controller: controller),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      final calibreField = find.byWidgetPredicate(
        (widget) =>
            widget is MacosTextField &&
            widget.placeholder == 'Automatic detection or custom path',
      );
      expect(calibreField, findsOneWidget);
      expect(find.text(CalibreService.installCommand), findsNothing);

      const draftPath = '/draft/Calibre.app/ebook-convert';
      await tester.enterText(calibreField, draftPath);
      await tester.tap(find.text('Detect again'));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump(const Duration(milliseconds: 1));

      expect(converter.customExecutables, [draftPath]);
      expect(controller.settings.calibreExecutable, isEmpty);
      expect(find.text(CalibreService.installCommand), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final class _RecordingBookConverter implements BookConverter {
  final List<String> customExecutables = [];

  @override
  Future<CalibreInstallation?> detect({String customExecutable = ''}) async {
    customExecutables.add(customExecutable);
    return null;
  }

  @override
  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  }) {
    throw UnsupportedError('Conversion is not used by this test.');
  }
}
