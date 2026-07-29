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
}
