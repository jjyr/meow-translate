import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/jobs/output_file_allocator.dart';

void main() {
  test('concurrent reservations always choose different files', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-output-allocator-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const allocator = OutputFileAllocator();

    final files = await Future.wait([
      for (var index = 0; index < 8; index++)
        allocator.reserve(
          directory: temporaryDirectory,
          sourcePath: '/books/shared.epub',
          targetLanguage: 'Simplified Chinese',
        ),
    ]);

    expect(files.map((file) => file.path).toSet(), hasLength(8));
    for (final file in files) {
      expect(await file.exists(), isTrue);
    }
  });
}
