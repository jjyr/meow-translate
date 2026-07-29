import 'dart:io';

import 'package:path/path.dart' as path;

final class OutputFileAllocator {
  const OutputFileAllocator();

  Future<OutputFileReservation> reserve({
    required Directory directory,
    required String sourcePath,
    required String targetLanguage,
    required String jobId,
  }) async {
    await directory.create(recursive: true);
    final sourceName = path.basenameWithoutExtension(sourcePath);
    final language = targetLanguage.replaceAll(
      RegExp(r'[^\w\-\u0080-\uFFFF]+'),
      '-',
    );

    for (var suffix = 1; suffix < 10000; suffix++) {
      final suffixText = suffix == 1 ? '' : ' ($suffix)';
      final output = File(
        path.join(directory.path, '$sourceName - $language$suffixText.epub'),
      );
      final lock = _lockFor(output);
      try {
        await lock.create(exclusive: true);
      } on FileSystemException {
        if (await lock.exists()) {
          continue;
        }
        rethrow;
      }
      if (await output.exists()) {
        await lock.delete();
        continue;
      }

      final staging = _stagingFor(output, jobId);
      if (await staging.exists()) {
        await staging.delete();
      }
      return OutputFileReservation._(
        output: output,
        staging: staging,
        lock: lock,
      );
    }
    throw const FileSystemException(
      'Unable to reserve a unique output filename.',
    );
  }

  Future<void> cleanInterruptedReservation({
    required String outputPath,
    required String jobId,
  }) async {
    final output = File(outputPath);
    final staging = _stagingFor(output, jobId);
    final lock = _lockFor(output);
    if (await staging.exists()) {
      await staging.delete();
    }
    if (await lock.exists()) {
      await lock.delete();
    }
    if (await output.exists()) {
      await output.delete();
    }
  }

  static File _lockFor(File output) => File('${output.path}.meow-reservation');

  static File _stagingFor(File output, String jobId) => File(
    path.join(output.parent.path, '.${path.basename(output.path)}.$jobId.tmp'),
  );
}

final class OutputFileReservation {
  const OutputFileReservation._({
    required this.output,
    required this.staging,
    required File lock,
  }) : _lock = lock;

  final File output;
  final File staging;
  final File _lock;

  Future<File> publish() async {
    if (!await staging.exists()) {
      throw const FileSystemException('The staged EPUB does not exist.');
    }
    if (await output.exists()) {
      throw FileSystemException(
        'The reserved output path is no longer available.',
        output.path,
      );
    }
    await staging.rename(output.path);
    if (await _lock.exists()) {
      try {
        await _lock.delete();
      } on FileSystemException {
        // The complete output is already atomically published. A stale hidden
        // lock is harmless and will be skipped by future allocations.
      }
    }
    return output;
  }

  Future<void> cancel() async {
    if (await staging.exists()) {
      await staging.delete();
    }
    if (await _lock.exists()) {
      await _lock.delete();
    }
  }
}
