import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/jobs/job_repository.dart';
import 'package:meow_translate/src/jobs/translation_job.dart';
import 'package:meow_translate/src/settings/app_settings.dart';
import 'package:meow_translate/src/storage/app_paths.dart';

void main() {
  late Directory temporaryDirectory;
  late AppPaths paths;
  late JobRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-job-repository-test-',
    );
    paths = AppPaths(
      supportDirectory: Directory('${temporaryDirectory.path}/support'),
      cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
    );
    repository = JobRepository(paths);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test(
    'concurrent saves are serialized and leave the latest valid JSON',
    () async {
      final first = _job('first');
      final second = _job('second');

      await Future.wait([
        repository.save([first]),
        repository.save([second]),
      ]);

      final decoded =
          jsonDecode(await paths.jobsFile.readAsString()) as List<dynamic>;
      expect(decoded, hasLength(1));
      expect((decoded.single as Map<String, dynamic>)['id'], 'second');
      expect((await repository.load()).single.id, 'second');
    },
  );

  test('save captures a snapshot before the caller mutates its list', () async {
    final jobs = [_job('captured')];

    final operation = repository.save(jobs);
    jobs
      ..clear()
      ..add(_job('mutated'));
    await operation;

    expect((await repository.load()).single.id, 'captured');
  });

  test('jobs file is private on POSIX systems', () async {
    await repository.save([_job('private')]);

    if (Platform.isMacOS || Platform.isLinux) {
      final mode = (await paths.jobsFile.stat()).mode & 0x1ff;
      expect(mode, 0x180);
    }
  });
}

TranslationJob _job(String id) => TranslationJob(
  id: id,
  sourcePath: '/books/$id.epub',
  sourceBookmark: 'source-bookmark',
  outputDirectory: '/output',
  outputDirectoryBookmark: 'output-bookmark',
  targetLanguage: 'English',
  keepOriginal: false,
  provider: TranslationProvider.deepseek,
  createdAt: DateTime.utc(2026),
  status: TranslationJobStatus.queued,
  totalUnits: 0,
  completedUnitIds: const {},
  failedUnitIds: const {},
);
