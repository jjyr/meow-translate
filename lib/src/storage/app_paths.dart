import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

final class AppPaths {
  const AppPaths({
    required this.supportDirectory,
    required this.cacheDirectory,
  });

  static Future<AppPaths> create() async {
    final support = await getApplicationSupportDirectory();
    final cache = await getApplicationCacheDirectory();
    final paths = AppPaths(supportDirectory: support, cacheDirectory: cache);
    await paths.supportDirectory.create(recursive: true);
    await paths.workspacesDirectory.create(recursive: true);
    return paths;
  }

  final Directory supportDirectory;
  final Directory cacheDirectory;

  File get configFile => File(path.join(supportDirectory.path, 'config.json'));

  File get jobsFile => File(path.join(supportDirectory.path, 'jobs.json'));

  Directory get jobLogsDirectory =>
      Directory(path.join(supportDirectory.path, 'logs'));

  File jobLogFor(String jobId) =>
      File(path.join(jobLogsDirectory.path, '$jobId.jsonl'));

  Directory get workspacesDirectory =>
      Directory(path.join(supportDirectory.path, 'workspaces'));

  Directory workspaceFor(String jobId) =>
      Directory(path.join(workspacesDirectory.path, jobId));

  Directory legacyWorkspaceFor(String jobId) =>
      Directory(path.join(cacheDirectory.path, 'workspaces', jobId));
}
