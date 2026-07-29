import 'dart:io';

import 'package:path/path.dart' as path;

final class OutputFileAllocator {
  const OutputFileAllocator();

  Future<File> reserve({
    required Directory directory,
    required String sourcePath,
    required String targetLanguage,
  }) async {
    await directory.create(recursive: true);
    final sourceName = path.basenameWithoutExtension(sourcePath);
    final language = targetLanguage.replaceAll(
      RegExp(r'[^\w\-\u0080-\uFFFF]+'),
      '-',
    );

    for (var suffix = 1; suffix < 10000; suffix++) {
      final suffixText = suffix == 1 ? '' : ' ($suffix)';
      final candidate = File(
        path.join(directory.path, '$sourceName - $language$suffixText.epub'),
      );
      try {
        return await candidate.create(exclusive: true);
      } on FileSystemException {
        if (!await candidate.exists()) {
          rethrow;
        }
      }
    }
    throw const FileSystemException(
      'Unable to reserve a unique output filename.',
    );
  }
}
