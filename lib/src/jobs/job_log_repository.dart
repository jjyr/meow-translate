import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../storage/app_paths.dart';

enum JobLogLevel { info, warning, error }

final class JobLogEntry {
  const JobLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  factory JobLogEntry.fromJson(Map<String, dynamic> json) => JobLogEntry(
    timestamp: DateTime.parse(json['timestamp'] as String),
    level: JobLogLevel.values.byName(json['level'] as String),
    message: json['message'] as String,
  );

  final DateTime timestamp;
  final JobLogLevel level;
  final String message;

  Map<String, Object> toJson() => {
    'timestamp': timestamp.toUtc().toIso8601String(),
    'level': level.name,
    'message': message,
  };

  String get displayText =>
      '${timestamp.toLocal().toIso8601String()} '
      '[${level.name.toUpperCase()}] $message';
}

class JobLogRepository {
  JobLogRepository(this.paths);

  final AppPaths paths;
  final Map<String, Future<void>> _writeTails = {};

  File fileFor(String jobId) => paths.jobLogFor(jobId);

  Future<void> append(
    String jobId,
    String message, {
    JobLogLevel level = JobLogLevel.info,
    Iterable<String> secrets = const [],
  }) {
    final sanitized = _redact(message, secrets);
    final entry = JobLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: sanitized,
    );
    final previous = _writeTails[jobId] ?? Future<void>.value();
    final operation = previous.then((_) async {
      final file = fileFor(jobId);
      await file.parent.create(recursive: true);
      final existed = await file.exists();
      await file.writeAsString(
        '${jsonEncode(entry.toJson())}\n',
        mode: FileMode.append,
        flush: true,
      );
      if (!existed && (Platform.isMacOS || Platform.isLinux)) {
        await Process.run('chmod', ['600', file.path]);
      }
    });
    _writeTails[jobId] = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<List<JobLogEntry>> read(String jobId) async {
    await _writeTails[jobId];
    final file = fileFor(jobId);
    if (!await file.exists()) {
      return [];
    }
    final entries = <JobLogEntry>[];
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          entries.add(JobLogEntry.fromJson(decoded));
        }
      } on FormatException {
        // Ignore an incomplete final line left by an interrupted append.
      }
    }
    return entries;
  }

  String _redact(String value, Iterable<String> secrets) {
    var sanitized = value.replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    for (final secret in secrets) {
      if (secret.trim().isNotEmpty) {
        sanitized = sanitized.replaceAll(secret, '[REDACTED]');
      }
    }
    return sanitized;
  }
}
