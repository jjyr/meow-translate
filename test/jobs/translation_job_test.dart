import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/jobs/translation_job.dart';
import 'package:meow_translate/src/settings/app_settings.dart';

void main() {
  test('job persistence omits model credentials', () {
    final json = _job().toJson();

    expect(json['provider'], 'codex');
    expect(json['source_bookmark'], 'source-bookmark');
    expect(json['output_directory_bookmark'], 'output-bookmark');
    expect(json.toString(), isNot(contains('api_key')));
    expect(json.toString(), isNot(contains('secret')));
  });

  test(
    'legacy model settings migrate provider without retaining credentials',
    () {
      final legacy = _job().toJson()
        ..remove('provider')
        ..['model_settings'] = {
          'provider': 'deepseek',
          'base_url': 'https://example.test',
          'model': 'model',
          'api_key': 'legacy-secret',
          'prompt': 'Translate.',
        };

      final migrated = TranslationJob.fromJson(legacy);
      final persisted = migrated.toJson();

      expect(migrated.provider, TranslationProvider.deepseek);
      expect(persisted['provider'], 'deepseek');
      expect(persisted.toString(), isNot(contains('legacy-secret')));
      expect(persisted.containsKey('model_settings'), isFalse);
    },
  );
}

TranslationJob _job() => TranslationJob(
  id: 'job-1',
  sourcePath: '/books/book.epub',
  sourceBookmark: 'source-bookmark',
  outputDirectory: '/output',
  outputDirectoryBookmark: 'output-bookmark',
  targetLanguage: 'Simplified Chinese',
  provider: TranslationProvider.codex,
  createdAt: DateTime.utc(2026),
  status: TranslationJobStatus.queued,
  totalUnits: 2,
  completedUnitIds: const {'unit-1'},
  failedUnitIds: const {},
);
