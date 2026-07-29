import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import 'jobs/job_controller.dart';
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
      home: RootWindow(controller: controller),
    );
  }
}
