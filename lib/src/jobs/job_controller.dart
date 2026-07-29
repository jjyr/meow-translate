import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../ebook/epub/epub_codec.dart';
import '../ebook/ebook_codec.dart';
import '../platform/desktop_services.dart';
import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';
import '../storage/app_paths.dart';
import '../translation/http_translation_engines.dart';
import '../translation/translation_engine.dart';
import '../translation/translation_models.dart';
import 'job_repository.dart';
import 'output_file_allocator.dart';
import 'translation_job.dart';

final class JobController extends ChangeNotifier {
  JobController({
    required this.paths,
    required this.settingsRepository,
    required this.jobRepository,
    required this.desktopServices,
    this.maximumConcurrentJobs = 2,
    this.outputFileAllocator = const OutputFileAllocator(),
  });

  final AppPaths paths;
  final SettingsRepository settingsRepository;
  final JobRepository jobRepository;
  final DesktopServices desktopServices;
  final int maximumConcurrentJobs;
  final OutputFileAllocator outputFileAllocator;
  final EbookCodec _codec = const EpubCodec();
  final Set<String> _runningJobIds = {};
  final Set<String> _abandonRequested = {};
  final Map<String, TranslationCancellationToken> _cancellationTokens = {};
  final Random _random = Random.secure();

  AppSettings settings = AppSettings.defaults();
  List<TranslationJob> jobs = [];
  bool initialized = false;
  String? initializationError;

  int get runningJobCount => jobs.where((job) => job.status.isRunning).length;

  Future<void> initialize() async {
    try {
      settings = await settingsRepository.load();
      jobs = await jobRepository.load();
      jobs = [
        for (final job in jobs)
          if (job.status.isRunning)
            job.copyWith(
              status: TranslationJobStatus.waitingForAction,
              errorMessage:
                  'Meow was closed while this job was running. Retry to resume.',
            )
          else
            job,
      ];
      await jobRepository.save(jobs);
    } on Object catch (error) {
      initializationError = error.toString();
    } finally {
      initialized = true;
      notifyListeners();
      if (initializationError == null) {
        _pump();
      }
    }
  }

  Future<void> updateSettings(AppSettings value) async {
    settings = value;
    notifyListeners();
    await settingsRepository.save(value);
  }

  Future<void> enqueue({
    required List<String> sourcePaths,
    required String outputDirectory,
    required String targetLanguage,
    required TranslationProvider provider,
  }) async {
    final outputBookmark =
        settings.outputDirectory == outputDirectory &&
            settings.outputDirectoryBookmark.isNotEmpty
        ? settings.outputDirectoryBookmark
        : await desktopServices.createBookmark(outputDirectory);
    final sourceBookmarks = <String, String>{};
    for (final sourcePath in sourcePaths) {
      sourceBookmarks[sourcePath] = await desktopServices.createBookmark(
        sourcePath,
      );
    }

    final now = DateTime.now();
    for (var index = 0; index < sourcePaths.length; index++) {
      final sourcePath = sourcePaths[index];
      final id =
          '${now.microsecondsSinceEpoch}-$index-'
          '${_random.nextInt(1 << 32).toRadixString(16)}';
      jobs.insert(
        0,
        TranslationJob(
          id: id,
          sourcePath: sourcePath,
          sourceBookmark: sourceBookmarks[sourcePath]!,
          outputDirectory: outputDirectory,
          outputDirectoryBookmark: outputBookmark,
          targetLanguage: targetLanguage,
          provider: provider,
          createdAt: now,
          status: TranslationJobStatus.queued,
          totalUnits: 0,
          completedUnitIds: const {},
          failedUnitIds: const {},
        ),
      );
    }
    await updateSettings(
      settings.copyWith(
        outputDirectory: outputDirectory,
        outputDirectoryBookmark: outputBookmark,
        targetLanguage: targetLanguage,
        lastProvider: provider,
      ),
    );
    await _persist();
    _pump();
  }

  Future<void> retry(String jobId) async {
    final job = jobById(jobId);
    if (job == null || job.status != TranslationJobStatus.waitingForAction) {
      return;
    }
    await _replace(
      job.copyWith(status: TranslationJobStatus.queued, clearError: true),
    );
    _pump();
  }

  Future<void> abandon(String jobId) async {
    final job = jobById(jobId);
    if (job == null || job.status == TranslationJobStatus.completed) {
      return;
    }
    _abandonRequested.add(jobId);
    _cancellationTokens[jobId]?.cancel();
    await _replace(
      job.copyWith(
        status: TranslationJobStatus.abandoned,
        errorMessage: 'The job was abandoned by the user.',
      ),
    );
    if (!_runningJobIds.contains(jobId)) {
      await _deleteWorkspace(jobId);
      _abandonRequested.remove(jobId);
    }
  }

  TranslationJob? jobById(String jobId) {
    for (final job in jobs) {
      if (job.id == jobId) {
        return job;
      }
    }
    return null;
  }

  void _pump() {
    while (_runningJobIds.length < maximumConcurrentJobs) {
      final next = jobs
          .where((job) => job.status == TranslationJobStatus.queued)
          .firstOrNull;
      if (next == null) {
        return;
      }
      _runningJobIds.add(next.id);
      unawaited(
        _run(next.id).whenComplete(() {
          _runningJobIds.remove(next.id);
          _pump();
        }),
      );
    }
  }

  Future<void> _run(String jobId) async {
    final cancellationToken = TranslationCancellationToken();
    _cancellationTokens[jobId] = cancellationToken;
    try {
      var job = jobById(jobId);
      if (job == null || _abandonRequested.contains(jobId)) {
        return;
      }
      await _replace(job.copyWith(status: TranslationJobStatus.unpacking));
      final workspace = paths.workspaceFor(jobId);
      final manifest = File(path.join(workspace.path, 'epub-workspace.json'));
      final EbookSession session;
      if (await manifest.exists()) {
        session = await _codec.restore(workspace);
      } else {
        final sourceAccess = await _startRequiredAccess(
          job.sourceBookmark,
          'Source access could not be restored. Add this book again.',
        );
        try {
          final refreshed = sourceAccess.refreshedBookmark;
          if (sourceAccess.resolvedPath != job.sourcePath ||
              (refreshed != null && refreshed != job.sourceBookmark)) {
            job = job.copyWith(
              sourcePath: sourceAccess.resolvedPath,
              sourceBookmark: refreshed ?? job.sourceBookmark,
            );
            await _replace(job);
          }
          session = await _codec.unpack(
            File(sourceAccess.resolvedPath),
            workspace: workspace,
          );
        } finally {
          await sourceAccess.close();
        }
      }

      job = jobById(jobId);
      if (job == null || await _stopIfAbandoned(jobId)) {
        return;
      }
      if (job.totalUnits == 0) {
        var count = 0;
        await for (final _ in session.readTranslationUnits()) {
          count++;
        }
        job = job.copyWith(totalUnits: count);
        await _replace(job);
      }

      await _replace(job.copyWith(status: TranslationJobStatus.translating));
      final modelSettings = settings.model(job.provider);
      final engine = _createEngine(modelSettings);
      try {
        await for (final unit in session.readTranslationUnits()) {
          job = jobById(jobId);
          if (job == null || await _stopIfAbandoned(jobId)) {
            return;
          }
          if (job.completedUnitIds.contains(unit.id)) {
            continue;
          }

          TranslationCompleted? completed;
          TranslationFailed? failed;
          await for (final event in engine.translate(
            TranslationRequest(
              chunk: TranslationChunk([unit]),
              targetLanguage: job.targetLanguage,
              prompt: modelSettings.prompt,
              cancellationToken: cancellationToken,
            ),
          )) {
            if (event is TranslationCompleted) {
              completed = event;
            } else if (event is TranslationFailed) {
              failed = event;
            } else if (event is TranslationCancelled) {
              break;
            }
          }

          if (await _stopIfAbandoned(jobId)) {
            return;
          }
          if (failed != null || completed == null) {
            final failedIds = {...job.failedUnitIds, unit.id};
            await _replace(
              job.copyWith(
                status: TranslationJobStatus.waitingForAction,
                failedUnitIds: failedIds,
                errorMessage:
                    failed?.message ?? 'The translation ended unexpectedly.',
              ),
            );
            return;
          }

          final translated = completed.units
              .where((value) => value.unitId == unit.id)
              .firstOrNull;
          if (translated == null) {
            throw StateError('The engine omitted translation unit ${unit.id}.');
          }
          await session.saveTranslation(unit, translated);
          job = job.copyWith(
            completedUnitIds: {...job.completedUnitIds, unit.id},
            failedUnitIds: {...job.failedUnitIds}..remove(unit.id),
            clearError: true,
          );
          await _replace(job);
        }
      } finally {
        engine.close();
      }

      job = jobById(jobId);
      if (job == null || await _stopIfAbandoned(jobId)) {
        return;
      }
      await _replace(job.copyWith(status: TranslationJobStatus.repacking));
      final outputAccess = await _startRequiredAccess(
        job.outputDirectoryBookmark,
        'Output folder access could not be restored. Add this book again.',
      );
      late final File output;
      try {
        final refreshed = outputAccess.refreshedBookmark;
        if (outputAccess.resolvedPath != job.outputDirectory ||
            (refreshed != null && refreshed != job.outputDirectoryBookmark)) {
          job = job.copyWith(
            outputDirectory: outputAccess.resolvedPath,
            outputDirectoryBookmark: refreshed ?? job.outputDirectoryBookmark,
          );
          await _replace(job);
        }
        output = await outputFileAllocator.reserve(
          directory: Directory(outputAccess.resolvedPath),
          sourcePath: job.sourcePath,
          targetLanguage: job.targetLanguage,
        );
        if (await _stopIfAbandoned(jobId)) {
          await output.delete();
          return;
        }
        try {
          await session.repack(output);
        } on Object {
          if (await output.exists()) {
            await output.delete();
          }
          rethrow;
        }
        if (await _stopIfAbandoned(jobId)) {
          await output.delete();
          return;
        }
      } finally {
        await outputAccess.close();
      }
      await _replace(
        job.copyWith(
          status: TranslationJobStatus.completed,
          outputPath: output.path,
          failedUnitIds: const {},
          clearError: true,
        ),
      );
      try {
        await desktopServices.notifyCompleted(
          jobId: job.id,
          outputPath: output.path,
        );
      } on Object catch (error) {
        debugPrint('Unable to show completion notification: $error');
      }
    } on Object catch (error) {
      final job = jobById(jobId);
      if (job != null && job.status != TranslationJobStatus.abandoned) {
        await _replace(
          job.copyWith(
            status: TranslationJobStatus.waitingForAction,
            errorMessage: error.toString(),
          ),
        );
      }
    } finally {
      _cancellationTokens.remove(jobId);
      if (_abandonRequested.contains(jobId)) {
        await _stopIfAbandoned(jobId);
      }
    }
  }

  TranslationEngine _createEngine(ModelSettings modelSettings) {
    return switch (modelSettings.provider) {
      TranslationProvider.deepseek => DeepSeekTranslationEngine(
        baseUrl: modelSettings.baseUrl,
        apiKey: modelSettings.apiKey,
        model: modelSettings.model,
      ),
      TranslationProvider.codex => CodexTranslationEngine(
        baseUrl: modelSettings.baseUrl,
        apiKey: modelSettings.apiKey,
        model: modelSettings.model,
      ),
    };
  }

  Future<SecurityScopedAccess> _startRequiredAccess(
    String bookmark,
    String message,
  ) {
    if (bookmark.isEmpty) {
      throw StateError(message);
    }
    return desktopServices.startAccess(bookmark);
  }

  Future<bool> _stopIfAbandoned(String jobId) async {
    if (!_abandonRequested.contains(jobId)) {
      return false;
    }
    await _deleteWorkspace(jobId);
    _abandonRequested.remove(jobId);
    return true;
  }

  Future<void> _deleteWorkspace(String jobId) async {
    final workspace = paths.workspaceFor(jobId);
    if (await workspace.exists()) {
      await workspace.delete(recursive: true);
    }
  }

  Future<void> _replace(TranslationJob updated) async {
    final index = jobs.indexWhere((job) => job.id == updated.id);
    if (index < 0) {
      return;
    }
    jobs[index] = updated;
    await _persist();
  }

  Future<void> _persist() async {
    await jobRepository.save(jobs);
    notifyListeners();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
