import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

final class CalibreInstallation {
  const CalibreInstallation({required this.executable, required this.version});

  final String executable;
  final String version;
}

abstract interface class BookConverter {
  Future<CalibreInstallation?> detect({String customExecutable = ''});

  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  });
}

final class CalibreService implements BookConverter {
  const CalibreService();

  static const installCommand = 'brew install --cask calibre';
  static const applicationExecutable =
      '/Applications/calibre.app/Contents/MacOS/ebook-convert';

  @override
  Future<CalibreInstallation?> detect({String customExecutable = ''}) async {
    final home = Platform.environment['HOME'];
    final candidates = <String>[
      if (customExecutable.trim().isNotEmpty) customExecutable.trim(),
      applicationExecutable,
      if (home != null && home.isNotEmpty)
        '$home/Applications/calibre.app/Contents/MacOS/ebook-convert',
      'ebook-convert',
    ];
    for (final executable in candidates.toSet()) {
      try {
        final result = await Process.run(executable, [
          '--version',
        ]).timeout(const Duration(seconds: 5));
        if (result.exitCode == 0) {
          final output = '${result.stdout}'.trim();
          return CalibreInstallation(
            executable: executable,
            version: output.isEmpty ? 'unknown' : output.split('\n').first,
          );
        }
      } on Object {
        // Try the next standard location.
      }
    }
    return null;
  }

  @override
  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  }) async {
    if (!await input.exists()) {
      throw FileSystemException(
        'The conversion input does not exist.',
        input.path,
      );
    }
    await output.parent.create(recursive: true);
    final temporaryOutput = File(
      path.join(
        output.parent.path,
        '.${path.basenameWithoutExtension(output.path)}.'
        '$pid-${DateTime.now().microsecondsSinceEpoch}.converting'
        '${path.extension(output.path)}',
      ),
    );
    try {
      final process = await Process.start(executable, [
        input.path,
        temporaryOutput.path,
      ]);
      final stdoutFuture = process.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final stderrFuture = process.stderr
          .transform(const SystemEncoding().decoder)
          .join();
      final exitCode = await process.exitCode;
      final stdout = await stdoutFuture;
      final stderr = await stderrFuture;
      if (exitCode != 0 || !await temporaryOutput.exists()) {
        final details = stderr.trim().isNotEmpty
            ? stderr.trim()
            : stdout.trim();
        throw BookConversionException(
          'ebook-convert failed with exit code $exitCode'
          '${details.isEmpty ? '.' : ': $details'}',
        );
      }

      // The temporary file is a sibling of the destination, so this publish is
      // an atomic rename on the destination filesystem.
      await temporaryOutput.rename(output.path);
    } on Object {
      if (await temporaryOutput.exists()) {
        await temporaryOutput.delete();
      }
      rethrow;
    }
  }
}

final class BookConversionException implements Exception {
  const BookConversionException(this.message);

  final String message;

  @override
  String toString() => 'BookConversionException: $message';
}
