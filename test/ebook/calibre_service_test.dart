import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/calibre_service.dart';

void main() {
  late Directory temporaryDirectory;
  late File executable;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-calibre-test-',
    );
    executable = File('${temporaryDirectory.path}/ebook-convert');
    await executable.writeAsString('''
#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "ebook-convert (calibre 9.0.0)"
  exit 0
fi
cp "\$1" "\$2"
''');
    await Process.run('chmod', ['755', executable.path]);
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('detects a custom ebook-convert executable and version', () async {
    const service = CalibreService();

    final installation = await service.detect(
      customExecutable: executable.path,
    );

    expect(installation, isNotNull);
    expect(installation!.executable, executable.path);
    expect(installation.version, contains('calibre 9.0.0'));
  });

  test('converts a book through ebook-convert', () async {
    const service = CalibreService();
    final input = File('${temporaryDirectory.path}/book.mobi');
    final output = File('${temporaryDirectory.path}/book.epub');
    await input.writeAsString('book payload');

    await service.convert(
      executable: executable.path,
      input: input,
      output: output,
    );

    expect(await output.readAsString(), 'book payload');
  });
}
