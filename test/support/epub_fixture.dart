import 'dart:io';

import 'package:archive/archive.dart';

const fixtureIdentifier = 'urn:uuid:meow-test-book';
const fixtureTitle = 'Meow Test Book';
const fixtureChapterPath = 'EPUB/chapter.xhtml';
const fixtureChapter = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>Meow Test Book</title></head>
  <body>
    <h1 id="chapter-one">Chapter One</h1>
    <p id="p1">Hello <em data-mark="yes">world</em>.</p>
  </body>
</html>
''';

Future<File> createEpubFixture(
  Directory directory, {
  String chapter = fixtureChapter,
}) async {
  final archive = Archive()
    ..add(
      ArchiveFile.noCompress(
        'mimetype',
        'application/epub+zip'.length,
        'application/epub+zip'.codeUnits,
      ),
    )
    ..add(
      ArchiveFile.string('META-INF/container.xml', '''<?xml version="1.0"?>
<container version="1.0"
 xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="EPUB/package.opf"
      media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>'''),
    )
    ..add(
      ArchiveFile.string(
        'EPUB/package.opf',
        '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
 version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="book-id">$fixtureIdentifier</dc:identifier>
    <dc:title>$fixtureTitle</dc:title>
    <dc:language>en</dc:language>
  </metadata>
  <manifest>
    <item id="chapter" href="chapter.xhtml"
      media-type="application/xhtml+xml"/>
    <item id="image" href="image.bin"
      media-type="application/octet-stream"/>
  </manifest>
  <spine>
    <itemref idref="chapter"/>
  </spine>
</package>''',
      ),
    )
    ..add(ArchiveFile.string(fixtureChapterPath, chapter))
    ..add(ArchiveFile.bytes('EPUB/image.bin', [0, 1, 2, 3, 254, 255]));
  archive.find('META-INF/container.xml')!.compression = CompressionType.deflate;
  archive.find('EPUB/package.opf')!.compression = CompressionType.deflate;
  archive.find(fixtureChapterPath)!.compression = CompressionType.deflate;
  archive.find('EPUB/image.bin')!.compression = CompressionType.deflate;

  final output = File('${directory.path}/fixture.epub');
  await output.writeAsBytes(ZipEncoder().encodeBytes(archive), flush: true);
  return output;
}

ArchiveSnapshot readArchiveSnapshot(File file) {
  final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
  final entries = <String, List<int>>{
    for (final entry in archive)
      if (entry.isFile) entry.name: List<int>.from(entry.content),
  };
  final names = archive.map((entry) => entry.name).toList(growable: false);
  final firstCompression = archive.first.compression;
  archive.clearSync();
  return ArchiveSnapshot(
    names: names,
    entries: entries,
    firstCompression: firstCompression,
  );
}

final class ArchiveSnapshot {
  const ArchiveSnapshot({
    required this.names,
    required this.entries,
    required this.firstCompression,
  });

  final List<String> names;
  final Map<String, List<int>> entries;
  final CompressionType? firstCompression;
}
