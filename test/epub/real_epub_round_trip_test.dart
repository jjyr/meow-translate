@Tags(['real-epub'])
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/epub/epub_codec.dart';

import '../support/epub_fixture.dart';

void main() {
  final sourcePath = Platform.environment['MEOW_TEST_EPUB'];
  final sourceExists = sourcePath != null && File(sourcePath).existsSync();

  test(
    'real EPUB survives unpack and no-op repack without payload changes',
    () async {
      final temporaryDirectory = await Directory.systemTemp.createTemp(
        'meow-real-epub-test-',
      );
      addTearDown(() async {
        if (await temporaryDirectory.exists()) {
          await temporaryDirectory.delete(recursive: true);
        }
      });

      final source = File(sourcePath!);
      const codec = EpubCodec();
      final session = await codec.unpack(
        source,
        workspace: Directory('${temporaryDirectory.path}/workspace'),
      );
      var unitCount = 0;
      await for (final _ in session.readTranslationUnits()) {
        unitCount++;
      }
      expect(unitCount, greaterThan(0));
      expect(session.packageInfo.identifier, isNotEmpty);

      final output = File('${temporaryDirectory.path}/round-trip.epub');
      await session.repack(output);
      final original = readArchiveSnapshot(source);
      final repacked = readArchiveSnapshot(output);

      expect(repacked.names, original.names);
      expect(repacked.entries.keys, original.entries.keys);
      for (final entry in original.entries.entries) {
        expect(
          repacked.entries[entry.key],
          entry.value,
          reason: 'Entry ${entry.key} changed during the real EPUB round trip.',
        );
      }
      expect(repacked.names.first, 'mimetype');
      expect(repacked.firstCompression, CompressionType.none);

      final restored = await codec.restore(
        Directory('${temporaryDirectory.path}/workspace'),
      );
      expect(restored.packageInfo.identifier, session.packageInfo.identifier);
    },
    skip: sourceExists
        ? false
        : 'Set MEOW_TEST_EPUB to a local DRM-free EPUB file.',
  );
}
