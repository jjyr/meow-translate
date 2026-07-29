import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/jobs/translation_job.dart';
import 'package:meow_translate/src/settings/app_settings.dart';

void main() {
  test('job persistence omits model credentials', () {
    final json = _job().toJson();

    expect(json['provider'], 'codexCli');
    expect(json['source_bookmark'], 'source-bookmark');
    expect(json['output_directory_bookmark'], 'output-bookmark');
    expect(json['keep_original'], isTrue);
    expect(json.toString(), isNot(contains('api_key')));
    expect(json.toString(), isNot(contains('secret')));
  });

  test('legacy jobs default to translated-only output', () {
    final legacy = _job().toJson()..remove('keep_original');

    expect(TranslationJob.fromJson(legacy).keepOriginal, isFalse);
  });
}

TranslationJob _job() => TranslationJob(
  id: 'job-1',
  sourcePath: '/books/book.epub',
  sourceBookmark: 'source-bookmark',
  outputDirectory: '/output',
  outputDirectoryBookmark: 'output-bookmark',
  targetLanguage: 'Simplified Chinese',
  keepOriginal: true,
  preserveSourceFormat: false,
  provider: TranslationProvider.codexCli,
  createdAt: DateTime.utc(2026),
  status: TranslationJobStatus.queued,
  totalUnits: 2,
  completedUnitIds: const {'unit-1'},
  failedUnitIds: const {},
);
