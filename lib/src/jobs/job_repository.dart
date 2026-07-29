import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';
import 'translation_job.dart';

final class JobRepository {
  JobRepository(this.paths);

  final AppPaths paths;
  Future<void> _writeTail = Future<void>.value();

  Future<List<TranslationJob>> load() async {
    if (!await paths.jobsFile.exists()) {
      return [];
    }
    final decoded = jsonDecode(await paths.jobsFile.readAsString());
    if (decoded is! List<dynamic>) {
      throw const FormatException('The Meow job history is invalid.');
    }
    return decoded
        .cast<Map<String, dynamic>>()
        .map(TranslationJob.fromJson)
        .toList(growable: true);
  }

  Future<void> save(List<TranslationJob> jobs) {
    final snapshot = List<Map<String, Object?>>.unmodifiable(
      jobs.map((job) => Map<String, Object?>.unmodifiable(job.toJson())),
    );
    final operation = _writeTail.then((_) => _writeSnapshot(snapshot));
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _writeSnapshot(List<Map<String, Object?>> snapshot) async {
    final target = paths.jobsFile;
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.create();
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', temporary.path]);
    }
    await temporary.writeAsString(
      const JsonEncoder.withIndent(' ').convert(snapshot),
      flush: true,
    );
    await temporary.rename(target.path);
    if (Platform.isMacOS || Platform.isLinux) {
      await Process.run('chmod', ['600', target.path]);
    }
  }
}
