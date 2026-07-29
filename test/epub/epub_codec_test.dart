import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/epub/epub_codec.dart';
import 'package:meow_translate/src/translation/translation_models.dart';

import '../support/epub_fixture.dart';

void main() {
  late Directory temporaryDirectory;
  late File source;
  const codec = EpubCodec();

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-epub-test-',
    );
    source = await createEpubFixture(temporaryDirectory);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('unpack discovers publication metadata and streaming units', () async {
    final workspace = Directory('${temporaryDirectory.path}/workspace');
    final session = await codec.unpack(source, workspace: workspace);

    expect(session.packageInfo.title, fixtureTitle);
    expect(session.packageInfo.identifier, fixtureIdentifier);
    expect(session.packageInfo.format, 'epub');

    final units = await session.readTranslationUnits().toList();
    expect(units.map((unit) => unit.kind), ['h1', 'p']);
    expect(units.last.sourceText, 'Hello world.');

    final restored = await codec.restore(workspace);
    expect(restored.packageInfo.identifier, fixtureIdentifier);
    expect(
      (await restored.readTranslationUnits().toList()).map((unit) => unit.id),
      units.map((unit) => unit.id),
    );
  });

  test('no-op repack preserves every uncompressed entry payload', () async {
    final original = readArchiveSnapshot(source);
    final session = await codec.unpack(
      source,
      workspace: Directory('${temporaryDirectory.path}/workspace'),
    );
    final output = File('${temporaryDirectory.path}/round-trip.epub');
    await output.writeAsString('reserved');

    await session.repack(output);
    final repacked = readArchiveSnapshot(output);

    expect(repacked.names, original.names);
    expect(repacked.entries.keys, original.entries.keys);
    for (final entry in original.entries.entries) {
      expect(
        repacked.entries[entry.key],
        entry.value,
        reason: 'Entry ${entry.key} changed during a no-op round trip.',
      );
    }
    expect(repacked.names.first, 'mimetype');
    expect(repacked.firstCompression, CompressionType.none);
  });

  test('translated repack changes only selected text ranges', () async {
    final session = await codec.unpack(
      source,
      workspace: Directory('${temporaryDirectory.path}/workspace'),
    );
    final paragraph = (await session.readTranslationUnits().toList())
        .singleWhere((unit) => unit.kind == 'p');
    final translatedFragments = <String, String>{
      for (final fragment in paragraph.fragments)
        fragment.id: switch (fragment.sourceText) {
          'Hello ' => '你好 ',
          'world' => '世界',
          '.' => '。',
          final value => value,
        },
    };
    await session.saveTranslation(
      paragraph,
      TranslatedUnit(unitId: paragraph.id, fragments: translatedFragments),
    );
    expect(await session.recordedTranslationUnitIds(), {paragraph.id});

    final output = File('${temporaryDirectory.path}/translated.epub');
    await session.repack(output);
    final original = readArchiveSnapshot(source);
    final repacked = readArchiveSnapshot(output);

    for (final entry in original.entries.entries) {
      if (entry.key == fixtureChapterPath) {
        continue;
      }
      expect(
        repacked.entries[entry.key],
        entry.value,
        reason: 'Untranslated entry ${entry.key} changed.',
      );
    }
    final translatedChapter = utf8.decode(
      repacked.entries[fixtureChapterPath]!,
    );
    expect(
      translatedChapter,
      fixtureChapter.replaceFirst(
        'Hello <em data-mark="yes">world</em>.',
        '你好 <em data-mark="yes">世界</em>。',
      ),
    );
    expect(
      translatedChapter,
      contains('<h1 id="chapter-one">Chapter One</h1>'),
    );
    expect(translatedChapter, contains('<em data-mark="yes">世界</em>'));
  });

  test(
    'bilingual repack keeps the original block before an id-free clone',
    () async {
      const originalBlock =
          '<p id="p1" class="lead">Hello '
          '<em id="em1" data-mark="yes"><span xml:id="word">world</span></em>.'
          '</p>';
      const translatedBlock =
          '<p class="lead">你好 '
          '<em data-mark="yes"><span>世界</span></em>。</p>';
      source = await createEpubFixture(
        temporaryDirectory,
        chapter: fixtureChapter.replaceFirst(
          '<p id="p1">Hello <em data-mark="yes">world</em>.</p>',
          originalBlock,
        ),
      );
      final original = readArchiveSnapshot(source);
      final session = await codec.unpack(
        source,
        workspace: Directory('${temporaryDirectory.path}/workspace'),
      );
      final paragraph = (await session.readTranslationUnits().toList())
          .singleWhere((unit) => unit.kind == 'p');
      await session.saveTranslation(
        paragraph,
        TranslatedUnit(
          unitId: paragraph.id,
          fragments: {
            for (final fragment in paragraph.fragments)
              fragment.id: switch (fragment.sourceText) {
                'Hello ' => '你好 ',
                'world' => '世界',
                '.' => '。',
                final value => value,
              },
          },
        ),
      );

      final output = File('${temporaryDirectory.path}/bilingual.epub');
      await session.repack(output, keepOriginal: true);
      final repacked = readArchiveSnapshot(output);
      final chapter = utf8.decode(repacked.entries[fixtureChapterPath]!);

      expect(chapter, contains('$originalBlock\n$translatedBlock'));
      expect(chapter.split(originalBlock), hasLength(2));
      expect(chapter.split(translatedBlock), hasLength(2));
      for (final entry in original.entries.entries) {
        if (entry.key == fixtureChapterPath) {
          continue;
        }
        expect(
          repacked.entries[entry.key],
          entry.value,
          reason: 'Untouched entry ${entry.key} changed.',
        );
      }
    },
  );

  test('translated repack does not double-escape named entities', () async {
    source = await createEpubFixture(
      temporaryDirectory,
      chapter: fixtureChapter.replaceFirst(
        'Hello <em data-mark="yes">world</em>.',
        'One&nbsp;thing',
      ),
    );
    final session = await codec.unpack(
      source,
      workspace: Directory('${temporaryDirectory.path}/workspace'),
    );
    final paragraph = (await session.readTranslationUnits().toList())
        .singleWhere((unit) => unit.kind == 'p');
    expect(paragraph.sourceText, 'One\u00a0thing');
    await session.saveTranslation(
      paragraph,
      TranslatedUnit(
        unitId: paragraph.id,
        fragments: {
          for (final fragment in paragraph.fragments)
            fragment.id: fragment.sourceText,
        },
      ),
    );

    final output = File('${temporaryDirectory.path}/named-entities.epub');
    await session.repack(output);
    final chapter = utf8.decode(
      readArchiveSnapshot(output).entries[fixtureChapterPath]!,
    );

    expect(chapter, contains('One\u00a0thing'));
    expect(chapter, isNot(contains('&amp;nbsp;')));
  });

  test('recovery truncates an interrupted final translation record', () async {
    final workspace = Directory('${temporaryDirectory.path}/workspace');
    final session = await codec.unpack(source, workspace: workspace);
    final paragraph = (await session.readTranslationUnits().toList())
        .singleWhere((unit) => unit.kind == 'p');
    await session.saveTranslation(
      paragraph,
      TranslatedUnit(
        unitId: paragraph.id,
        fragments: {
          for (final fragment in paragraph.fragments)
            fragment.id: fragment.sourceText,
        },
      ),
    );
    final transcript = File('${workspace.path}/translations.jsonl');
    await transcript.writeAsString(
      '{"unit_id":"interrupted',
      mode: FileMode.append,
      flush: true,
    );

    expect(await session.recordedTranslationUnitIds(), {paragraph.id});
    final repaired = await transcript.readAsString();
    expect(repaired, endsWith('\n'));
    expect(repaired, isNot(contains('interrupted')));

    final output = File('${temporaryDirectory.path}/recovered.epub');
    await session.repack(output);
    expect(readArchiveSnapshot(output).entries, contains(fixtureChapterPath));
  });

  test('unpack rejects a ZIP path traversal entry', () async {
    final archive = Archive()
      ..add(
        ArchiveFile.noCompress(
          'mimetype',
          'application/epub+zip'.length,
          'application/epub+zip'.codeUnits,
        ),
      )
      ..add(ArchiveFile.string('../outside.txt', 'unsafe'));
    final unsafe = File('${temporaryDirectory.path}/unsafe.epub');
    await unsafe.writeAsBytes(ZipEncoder().encodeBytes(archive));

    expect(
      () => codec.unpack(
        unsafe,
        workspace: Directory('${temporaryDirectory.path}/unsafe-workspace'),
      ),
      throwsA(isA<Exception>()),
    );
  });
}
