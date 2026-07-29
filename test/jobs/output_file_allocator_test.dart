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

    final reservations = await Future.wait([
      for (var index = 0; index < 8; index++)
        allocator.reserve(
          directory: temporaryDirectory,
          sourcePath: '/books/shared.epub',
          targetLanguage: 'Simplified Chinese',
          jobId: 'job-$index',
        ),
    ]);

    expect(
      reservations.map((reservation) => reservation.output.path).toSet(),
      hasLength(8),
    );
    for (final reservation in reservations) {
      expect(await reservation.output.exists(), isFalse);
      await reservation.staging.writeAsString('complete epub');
      expect(await reservation.output.exists(), isFalse);
      final output = await reservation.publish();
      expect(await output.readAsString(), 'complete epub');
      await reservation.releaseOwnership();
    }
  });

  test('interrupted staging files can be cleaned and reserved again', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-output-cleanup-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const allocator = OutputFileAllocator();
    final interrupted = await allocator.reserve(
      directory: temporaryDirectory,
      sourcePath: '/books/shared.epub',
      targetLanguage: 'English',
      jobId: 'interrupted',
    );
    await interrupted.staging.writeAsString('partial zip');

    await allocator.cleanInterruptedReservation(
      outputPath: interrupted.output.path,
      jobId: 'interrupted',
    );
    final replacement = await allocator.reserve(
      directory: temporaryDirectory,
      sourcePath: '/books/shared.epub',
      targetLanguage: 'English',
      jobId: 'replacement',
    );

    expect(replacement.output.path, interrupted.output.path);
    expect(await interrupted.staging.exists(), isFalse);
    await replacement.cancel();
  });

  test('cleanup cannot delete output owned by a different job', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-output-ownership-test-',
    );
    addTearDown(() => temporaryDirectory.delete(recursive: true));
    const allocator = OutputFileAllocator();
    final first = await allocator.reserve(
      directory: temporaryDirectory,
      sourcePath: '/books/shared.epub',
      targetLanguage: 'English',
      jobId: 'job-a',
    );
    await first.cancel();
    final second = await allocator.reserve(
      directory: temporaryDirectory,
      sourcePath: '/books/shared.epub',
      targetLanguage: 'English',
      jobId: 'job-b',
    );
    await second.staging.writeAsString('job b output');
    await second.publish();

    final cleaned = await allocator.cleanInterruptedReservation(
      outputPath: first.output.path,
      jobId: 'job-a',
    );

    expect(cleaned, isFalse);
    expect(await second.output.readAsString(), 'job b output');
    await second.releaseOwnership();
  });
}
