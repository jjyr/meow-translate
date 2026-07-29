import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/settings/app_settings.dart';
import 'package:meow_translate/src/ui/operation_sheet.dart';

void main() {
  test('legacy output paths without bookmarks require reselection', () {
    final settings = AppSettings.defaults().copyWith(
      outputDirectory: '/legacy/output',
    );

    expect(rememberedOutputDirectory(settings), isEmpty);
  });

  test('bookmarked output paths remain available as the remembered choice', () {
    final settings = AppSettings.defaults().copyWith(
      outputDirectory: '/bookmarked/output',
      outputDirectoryBookmark: 'bookmark',
    );

    expect(rememberedOutputDirectory(settings), '/bookmarked/output');
  });

  test('bilingual output uses the remembered setting', () {
    final settings = AppSettings.defaults().copyWith(keepOriginal: true);

    expect(rememberedKeepOriginal(settings), isTrue);
  });
}
