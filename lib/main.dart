import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'src/app.dart';
import 'src/jobs/job_controller.dart';
import 'src/jobs/job_repository.dart';
import 'src/platform/desktop_services.dart';
import 'src/settings/settings_repository.dart';
import 'src/storage/app_paths.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && Platform.isMacOS) {
    await const MacosWindowUtilsConfig().apply();
  }

  final paths = await AppPaths.create();
  final desktopServices = DesktopServices();
  await desktopServices.initialize();
  final controller = JobController(
    paths: paths,
    settingsRepository: SettingsRepository(paths),
    jobRepository: JobRepository(paths),
    desktopServices: desktopServices,
  );
  await controller.initialize();
  runApp(MeowApp(controller: controller));
}
