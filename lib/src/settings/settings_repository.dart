import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';
import 'app_settings.dart';

final class SettingsRepository {
  const SettingsRepository(this.paths);

  final AppPaths paths;

  Future<AppSettings> load() async {
    if (!await paths.configFile.exists()) {
      final settings = AppSettings.defaults();
      await save(settings);
      return settings;
    }
    final decoded = jsonDecode(await paths.configFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The Meow configuration is invalid.');
    }
    return AppSettings.fromJson(decoded);
  }

  Future<void> save(AppSettings settings) async {
    final target = paths.configFile;
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.create();
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', temporary.path]);
    }
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
    await temporary.rename(target.path);
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', target.path]);
    }
  }
}
