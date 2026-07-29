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
}
