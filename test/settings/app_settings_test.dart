import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/settings/app_settings.dart';

void main() {
  test('bilingual output defaults off for existing settings', () {
    final legacy = AppSettings.defaults().toJson()..remove('keep_original');

    expect(AppSettings.fromJson(legacy).keepOriginal, isFalse);
  });

  test('bilingual output survives settings serialization', () {
    final settings = AppSettings.defaults().copyWith(keepOriginal: true);

    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.keepOriginal, isTrue);
    expect(restored.toJson()['keep_original'], isTrue);
  });

  test('model guidance uses the plain-text configuration schema', () {
    final settings = AppSettings.defaults().withModel(
      ModelSettings.defaults(
        TranslationProvider.deepseek,
      ).copyWith(prompt: 'Keep the prose concise.'),
    );

    final json = settings.toJson();
    final models = json['models'] as Map<String, Object>;
    final deepSeek = models['deepseek'] as Map<String, Object>;
    final restored = AppSettings.fromJson(json);

    expect(json['version'], 4);
    expect(deepSeek['translation_guidance'], 'Keep the prose concise.');
    expect(deepSeek.containsKey('prompt'), isFalse);
    expect(
      restored.model(TranslationProvider.deepseek).prompt,
      'Keep the prose concise.',
    );
  });

  test('obsolete prompt fields are ignored without migration', () {
    final json = AppSettings.defaults().toJson();
    final models = json['models'] as Map<String, Object>;
    (models['deepseek'] as Map<String, Object>)
      ..remove('translation_guidance')
      ..['prompt'] = 'Return JSON only.';

    final restored = AppSettings.fromJson(json);

    expect(
      restored.model(TranslationProvider.deepseek).prompt,
      defaultTranslationPrompt,
    );
  });
}
