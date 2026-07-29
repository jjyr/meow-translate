import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/jobs/job_log_repository.dart';
import 'package:meow_translate/src/storage/app_paths.dart';

void main() {
  late Directory temporaryDirectory;
  late JobLogRepository repository;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-job-log-test-',
    );
    repository = JobLogRepository(
      AppPaths(
        supportDirectory: temporaryDirectory,
        cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
      ),
    );
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('persists ordered log entries', () async {
    await repository.append('job-1', 'Job started.');
    await repository.append('job-1', 'Unit failed.', level: JobLogLevel.error);

    final entries = await repository.read('job-1');

    expect(entries.map((entry) => entry.message), [
      'Job started.',
      'Unit failed.',
    ]);
    expect(entries.last.level, JobLogLevel.error);
  });

  test('redacts API keys and bearer credentials', () async {
    await repository.append(
      'job-1',
      'key=super-secret Authorization: Bearer token-value',
      secrets: const ['super-secret'],
    );

    final contents = await repository.fileFor('job-1').readAsString();

    expect(contents, isNot(contains('super-secret')));
    expect(contents, isNot(contains('token-value')));
    expect(contents, contains('[REDACTED]'));
  });
}
