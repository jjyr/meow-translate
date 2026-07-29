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
      var createdLock = false;
      try {
        await lock.create(exclusive: true);
        createdLock = true;
        await lock.writeAsString(jobId, flush: true);
      } on FileSystemException {
        if (createdLock) {
          if (await lock.exists()) {
            await lock.delete();
          }
          rethrow;
        }
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

  Future<bool> cleanInterruptedReservation({
    required String outputPath,
    required String jobId,
  }) async {
    final output = File(outputPath);
    final staging = _stagingFor(output, jobId);
    final lock = _lockFor(output);
    if (await staging.exists()) {
      await staging.delete();
    }
    if (!await _isOwnedBy(lock, jobId)) {
      return false;
    }
    if (await output.exists()) {
      await output.delete();
    }
    await lock.delete();
    return true;
  }

  static File _lockFor(File output) => File('${output.path}.meow-reservation');

  static File _stagingFor(File output, String jobId) => File(
    path.join(output.parent.path, '.${path.basename(output.path)}.$jobId.tmp'),
  );

  static Future<bool> _isOwnedBy(File lock, String jobId) async {
    if (!await lock.exists()) {
      return false;
    }
    try {
      return await lock.readAsString() == jobId;
    } on FileSystemException {
      return false;
    }
  }
}

final class OutputFileReservation {
  OutputFileReservation._({
    required this.output,
    required this.staging,
    required File lock,
  }) : _lock = lock;

  final File output;
  final File staging;
  final File _lock;
  bool _published = false;

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
    _published = true;
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

  Future<void> rollback() async {
    if (_published && await output.exists()) {
      await output.delete();
    }
    await cancel();
  }

  Future<void> releaseOwnership() async {
    if (!await _lock.exists()) {
      return;
    }
    try {
      await _lock.delete();
    } on FileSystemException {
      // The completed output is already durable. A stale hidden marker is
      // harmless because allocators also verify that the final path exists.
    }
  }
}
