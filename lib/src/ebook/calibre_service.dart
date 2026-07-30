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
  const CalibreService({this.detectionTimeout = const Duration(seconds: 5)});

  static const installCommand = 'brew install --cask calibre';
  static const applicationExecutable =
      '/Applications/calibre.app/Contents/MacOS/ebook-convert';
  static const _terminationGracePeriod = Duration(milliseconds: 250);

  final Duration detectionTimeout;

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
      final installation = await _detectCandidate(executable);
      if (installation != null) {
        return installation;
      }
    }
    return null;
  }

  Future<CalibreInstallation?> _detectCandidate(String executable) async {
    Process? process;
    _BoundedProcessOutput? stdout;
    _BoundedProcessOutput? stderr;
    try {
      process = await Process.start(executable, ['--version']);
      stdout = _BoundedProcessOutput(process.stdout);
      stderr = _BoundedProcessOutput(process.stderr);
      final exitCode = await _waitForProcess(
        process,
        stdout,
        stderr,
      ).timeout(detectionTimeout);
      if (exitCode != 0) {
        return null;
      }
      final output = stdout.text.trim();
      return CalibreInstallation(
        executable: executable,
        version: output.isEmpty ? 'unknown' : output.split('\n').first,
      );
    } on Object {
      if (process != null) {
        await _terminateAndReap(process);
      }
      return null;
    } finally {
      await stdout?.cancel();
      await stderr?.cancel();
    }
  }

  Future<int> _waitForProcess(
    Process process,
    _BoundedProcessOutput stdout,
    _BoundedProcessOutput stderr,
  ) async {
    final exitCode = await process.exitCode;
    await Future.wait([stdout.done, stderr.done]);
    return exitCode;
  }

  Future<void> _terminateAndReap(Process process) async {
    if (Platform.isWindows) {
      process.kill();
      try {
        await process.exitCode.timeout(_terminationGracePeriod);
      } on TimeoutException {
        process.kill();
      }
      return;
    }

    final processIds = await _suspendProcessTree(process.pid);
    for (final processId in processIds.reversed) {
      Process.killPid(processId, ProcessSignal.sigkill);
    }
    try {
      await process.exitCode.timeout(_terminationGracePeriod);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await _waitForProcessIdsToExit(
      processIds.where((processId) => processId != process.pid),
    );
  }

  Future<List<int>> _suspendProcessTree(int rootProcessId) async {
    final processIds = <int>[];
    final pending = <int>[rootProcessId];
    final seen = <int>{};
    while (pending.isNotEmpty) {
      final processId = pending.removeLast();
      if (!seen.add(processId)) {
        continue;
      }
      Process.killPid(processId, ProcessSignal.sigstop);
      processIds.add(processId);
      pending.addAll(await _childProcessIds(processId));
    }
    return processIds;
  }

  Future<List<int>> _childProcessIds(int parentProcessId) async {
    try {
      final result = await Process.run('/usr/bin/pgrep', [
        '-P',
        '$parentProcessId',
      ]);
      if (result.exitCode != 0) {
        return const [];
      }
      return '${result.stdout}'
          .split(RegExp(r'\s+'))
          .map(int.tryParse)
          .whereType<int>()
          .toList();
    } on Object {
      return const [];
    }
  }

  Future<void> _waitForProcessIdsToExit(Iterable<int> processIds) async {
    final remaining = processIds.toSet();
    final deadline = DateTime.now().add(_terminationGracePeriod);
    while (remaining.isNotEmpty && DateTime.now().isBefore(deadline)) {
      for (final processId in remaining.toList()) {
        if (!await _isProcessRunning(processId)) {
          remaining.remove(processId);
        }
      }
      if (remaining.isNotEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  }

  Future<bool> _isProcessRunning(int processId) async {
    try {
      final result = await Process.run('/bin/kill', ['-0', '$processId']);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
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

final class _BoundedProcessOutput {
  _BoundedProcessOutput(Stream<List<int>> source) {
    _subscription = source
        .transform(const SystemEncoding().decoder)
        .listen(
          _append,
          onError: (Object _, StackTrace _) => _complete(),
          onDone: _complete,
        );
  }

  static const _maximumLength = 16 * 1024;

  final StringBuffer _buffer = StringBuffer();
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<String> _subscription;

  Future<void> get done => _done.future;

  String get text => _buffer.toString();

  void _append(String value) {
    final remaining = _maximumLength - _buffer.length;
    if (remaining <= 0) {
      return;
    }
    _buffer.write(
      value.length <= remaining ? value : value.substring(0, remaining),
    );
  }

  void _complete() {
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  Future<void> cancel() async {
    await _subscription.cancel();
    _complete();
  }
}

final class BookConversionException implements Exception {
  const BookConversionException(this.message);

  final String message;

  @override
  String toString() => 'BookConversionException: $message';
}
