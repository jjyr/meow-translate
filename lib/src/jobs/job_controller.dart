import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../ebook/epub/epub_codec.dart';
import '../ebook/ebook_codec.dart';
import '../ebook/book_format.dart';
import '../ebook/calibre_service.dart';
import '../platform/desktop_services.dart';
import '../settings/app_settings.dart';
import '../settings/settings_repository.dart';
import '../storage/app_paths.dart';
import '../translation/http_translation_engines.dart';
import '../translation/codex_cli_translation_engine.dart';
import '../translation/translation_engine.dart';
import '../translation/translation_models.dart';
import 'job_repository.dart';
import 'job_log_repository.dart';
import 'output_file_allocator.dart';
import 'translation_job.dart';

typedef TranslationEngineFactory =
    TranslationEngine Function(ModelSettings modelSettings);

final class JobController extends ChangeNotifier {
  JobController({
    required this.paths,
    required this.settingsRepository,
    required this.jobRepository,
    required this.desktopServices,
    this.maximumConcurrentJobs = 2,
    this.outputFileAllocator = const OutputFileAllocator(),
    BookConverter? bookConverter,
    JobLogRepository? jobLogRepository,
    EbookCodec? codec,
    TranslationEngineFactory? translationEngineFactory,
  }) : _codec = codec ?? const EpubCodec(),
       _bookConverter = bookConverter ?? const CalibreService(),
       jobLogRepository = jobLogRepository ?? JobLogRepository(paths),
       _translationEngineFactory =
           translationEngineFactory ?? createTranslationEngine;

  final AppPaths paths;
  final SettingsRepository settingsRepository;
  final JobRepository jobRepository;
  final DesktopServices desktopServices;
  final int maximumConcurrentJobs;
  final OutputFileAllocator outputFileAllocator;
  final JobLogRepository jobLogRepository;
  final EbookCodec _codec;
  final BookConverter _bookConverter;
  final TranslationEngineFactory _translationEngineFactory;
  final Set<String> _runningJobIds = {};
  final Set<String> _abandonRequested = {};
  final Set<String> _pauseRequested = {};
  final Map<String, TranslationCancellationToken> _cancellationTokens = {};
  final Random _random = Random.secure();
  static const _maximumConsecutiveTranslationFailures = 2;

  AppSettings settings = AppSettings.defaults();
  List<TranslationJob> jobs = [];
  bool initialized = false;
  String? initializationError;
  CalibreInstallation? calibreInstallation;
  bool checkingCalibre = false;

  int get runningJobCount => jobs.where((job) => job.status.isRunning).length;

  bool isJobRunning(String jobId) => _runningJobIds.contains(jobId);

  Future<void> initialize() async {
    try {
      settings = await settingsRepository.load();
      await refreshCalibre();
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
      for (var index = 0; index < jobs.length; index++) {
        final job = jobs[index];
        if (job.status == TranslationJobStatus.completed ||
            job.outputPath == null) {
          continue;
        }
        try {
          jobs[index] = await _cleanInterruptedOutput(job);
        } on Object catch (error) {
          debugPrint('Unable to clean interrupted output: $error');
        }
      }
      await jobRepository.save(jobs);
      for (final job in jobs) {
        if (job.status == TranslationJobStatus.completed ||
            job.status == TranslationJobStatus.abandoned) {
          try {
            await _deleteWorkspace(job.id);
          } on Object catch (error) {
            debugPrint('Unable to clean terminal workspace: $error');
          }
        }
      }
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
    await refreshCalibre();
  }

  Future<void> refreshCalibre() async {
    checkingCalibre = true;
    notifyListeners();
    calibreInstallation = await _bookConverter.detect(
      customExecutable: settings.calibreExecutable,
    );
    checkingCalibre = false;
    notifyListeners();
  }

  Future<void> enqueue({
    required List<String> sourcePaths,
    required String outputDirectory,
    required String targetLanguage,
    required bool keepOriginal,
    required bool preserveSourceFormat,
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
          keepOriginal: keepOriginal,
          preserveSourceFormat: preserveSourceFormat,
          provider: provider,
          createdAt: now,
          status: TranslationJobStatus.queued,
          totalUnits: 0,
          completedUnitIds: const {},
          failedUnitIds: const {},
        ),
      );
      await _log(
        id,
        'Job queued for ${path.basename(sourcePath)} '
        '(${BookFormat.fromPath(sourcePath)?.name.toUpperCase() ?? 'UNKNOWN'}).',
      );
    }
    await updateSettings(
      settings.copyWith(
        outputDirectory: outputDirectory,
        outputDirectoryBookmark: outputBookmark,
        targetLanguage: targetLanguage,
        keepOriginal: keepOriginal,
        preserveSourceFormat: preserveSourceFormat,
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
    await _log(jobId, 'Retrying failed and incomplete translation units.');
    _pump();
  }

  Future<void> pause(String jobId) async {
    final job = jobById(jobId);
    if (job == null ||
        job.status == TranslationJobStatus.paused ||
        job.status == TranslationJobStatus.completed ||
        job.status == TranslationJobStatus.abandoned) {
      return;
    }
    _pauseRequested.add(jobId);
    if (job.status == TranslationJobStatus.queued) {
      await _replace(
        job.copyWith(status: TranslationJobStatus.paused, clearError: true),
      );
      await _log(jobId, 'Job paused while queued.');
      return;
    }
    if (job.status == TranslationJobStatus.translating) {
      _cancellationTokens[jobId]?.cancel();
      await _log(jobId, 'Pause requested; cancelling the active translation.');
    } else {
      await _log(
        jobId,
        'Pause requested; the current ${job.status.label.toLowerCase()} '
        'phase will finish first.',
      );
    }
  }

  Future<void> resume(String jobId) async {
    final job = jobById(jobId);
    if (job == null || job.status != TranslationJobStatus.paused) {
      return;
    }
    _pauseRequested.remove(jobId);
    final resumed = await _replace(
      job.copyWith(status: TranslationJobStatus.queued, clearError: true),
      allowPausedTransition: true,
    );
    if (!resumed) return;
    await _log(jobId, 'Job resumed.');
    _pump();
  }

  Future<void> retranslateAll(String jobId) async {
    final job = jobById(jobId);
    if (job == null ||
        job.status.isRunning ||
        job.status == TranslationJobStatus.queued ||
        job.status == TranslationJobStatus.abandoned) {
      return;
    }
    _pauseRequested.remove(jobId);
    await _deleteWorkspace(jobId);
    final queued = await _replace(
      job.copyWith(
        status: TranslationJobStatus.queued,
        totalUnits: 0,
        completedUnitIds: const {},
        failedUnitIds: const {},
        clearError: true,
        clearOutputPath: true,
      ),
      allowPausedTransition: true,
    );
    if (!queued) return;
    await _log(jobId, 'All previous translations were cleared.');
    _pump();
  }

  Future<List<JobLogEntry>> readJobLog(String jobId) =>
      jobLogRepository.read(jobId);

  File jobLogFile(String jobId) => jobLogRepository.fileFor(jobId);

  Future<void> abandon(String jobId) async {
    final job = jobById(jobId);
    if (job == null || job.status == TranslationJobStatus.completed) {
      return;
    }
    _abandonRequested.add(jobId);
    _pauseRequested.remove(jobId);
    _cancellationTokens[jobId]?.cancel();
    await _replace(
      job.copyWith(
        status: TranslationJobStatus.abandoned,
        errorMessage: 'The job was abandoned by the user.',
      ),
    );
    await _log(jobId, 'Job abandoned by the user.', level: JobLogLevel.warning);
    if (!_runningJobIds.contains(jobId)) {
      final abandoned = jobById(jobId);
      if (abandoned?.outputPath != null) {
        try {
          await _replace(await _cleanInterruptedOutput(abandoned!));
        } on Object catch (error) {
          debugPrint('Unable to clean abandoned output: $error');
        }
      }
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
      await _log(jobId, 'Job started for ${path.basename(job.sourcePath)}.');
      await _migrateLegacyWorkspace(jobId);
      job = jobById(jobId);
      if (job == null ||
          await _stopIfAbandoned(jobId) ||
          await _stopIfPaused(jobId)) {
        return;
      }
      final session = await _prepareSession(jobId);
      if (session == null) return;

      job = jobById(jobId);
      if (job == null ||
          await _stopIfAbandoned(jobId) ||
          await _stopIfPaused(jobId)) {
        return;
      }
      final recordedUnitIds = await session.recordedTranslationUnitIds();
      job = jobById(jobId);
      if (job == null ||
          await _stopIfAbandoned(jobId) ||
          await _stopIfPaused(jobId)) {
        return;
      }
      if (job.completedUnitIds.difference(recordedUnitIds).isNotEmpty) {
        job = job.copyWith(
          completedUnitIds: const {},
          failedUnitIds: const {},
          clearError: true,
        );
        if (!await _replace(job)) {
          return;
        }
      }
      if (job.totalUnits == 0) {
        var count = 0;
        await for (final _ in session.readTranslationUnits()) {
          if (await _stopIfAbandoned(jobId) || await _stopIfPaused(jobId)) {
            return;
          }
          count++;
        }
        job = jobById(jobId);
        if (job == null ||
            await _stopIfAbandoned(jobId) ||
            await _stopIfPaused(jobId)) {
          return;
        }
        job = job.copyWith(totalUnits: count);
        if (!await _replace(job)) {
          return;
        }
      }

      job = jobById(jobId);
      if (job == null ||
          await _stopIfAbandoned(jobId) ||
          await _stopIfPaused(jobId)) {
        return;
      }
      if (!await _replace(
        job.copyWith(status: TranslationJobStatus.translating),
      )) {
        return;
      }
      await _log(
        jobId,
        'Translation started with ${job.provider.label}; '
        '${job.completedUnits} of ${job.totalUnits} units already complete.',
      );
      job = jobById(jobId);
      if (job == null || await _stopIfAbandoned(jobId)) {
        return;
      }
      final modelSettings = settings.model(job.provider);
      TranslationEngine? engine;
      var consecutiveFailures = 0;
      var circuitBreakerOpened = false;
      try {
        await for (final unit in session.readTranslationUnits()) {
          job = jobById(jobId);
          if (job == null ||
              await _stopIfAbandoned(jobId) ||
              await _stopIfPaused(jobId)) {
            return;
          }
          if (job.completedUnitIds.contains(unit.id)) {
            continue;
          }
          await _log(jobId, 'Translating unit ${unit.id}.');

          engine ??= _translationEngineFactory(modelSettings);
          TranslationCompleted? completed;
          TranslationFailed? failed;
          await for (final event in engine.translate(
            TranslationRequest(
              unit: unit,
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
          if (await _stopIfPaused(jobId)) {
            return;
          }
          if (failed != null || completed == null) {
            final failedIds = {...job.failedUnitIds, unit.id};
            final message =
                failed?.message ?? 'The translation ended unexpectedly.';
            await _replace(
              job.copyWith(failedUnitIds: failedIds, errorMessage: message),
            );
            await _log(
              jobId,
              'Unit ${unit.id} failed: $message',
              level: JobLogLevel.error,
            );
            engine.close();
            engine = null;
            consecutiveFailures++;
            if (consecutiveFailures >= _maximumConsecutiveTranslationFailures) {
              circuitBreakerOpened = true;
              await _log(
                jobId,
                'Translation stopped after $consecutiveFailures consecutive '
                'engine failures. Retry the failed units after checking the '
                'translation engine settings.',
                level: JobLogLevel.warning,
              );
              break;
            }
            continue;
          }

          consecutiveFailures = 0;
          final translated = completed.unit;
          if (translated.unitId != unit.id) {
            throw StateError('The engine omitted translation unit ${unit.id}.');
          }
          await session.saveTranslation(unit, translated);
          job = jobById(jobId);
          if (job == null || await _stopIfAbandoned(jobId)) {
            return;
          }
          job = job.copyWith(
            completedUnitIds: {...job.completedUnitIds, unit.id},
            failedUnitIds: {...job.failedUnitIds}..remove(unit.id),
            clearError: true,
          );
          if (!await _replace(job)) {
            return;
          }
          await _log(jobId, 'Unit ${unit.id} translated successfully.');
        }
      } finally {
        engine?.close();
      }

      job = jobById(jobId);
      if (job == null ||
          await _stopIfAbandoned(jobId) ||
          await _stopIfPaused(jobId)) {
        return;
      }
      if (job.failedUnitIds.isNotEmpty) {
        await _log(
          jobId,
          'Translation stopped with ${job.failedUnitIds.length} failed unit(s).',
          level: JobLogLevel.warning,
        );
        await _replace(
          job.copyWith(
            status: TranslationJobStatus.waitingForAction,
            errorMessage: circuitBreakerOpened
                ? 'Translation stopped after repeated engine failures. '
                      '${job.failedUnitIds.length} unit(s) failed; check the '
                      'engine settings and retry the failed units.'
                : '${job.failedUnitIds.length} translation unit(s) failed.',
          ),
        );
        return;
      }
      if (!await _replace(
        job.copyWith(status: TranslationJobStatus.repacking),
      )) {
        return;
      }
      await _log(jobId, 'Repacking translated EPUB.');
      job = jobById(jobId);
      if (job == null || await _stopIfAbandoned(jobId)) {
        return;
      }
      final outputAccess = await _startRequiredAccess(
        job.outputDirectoryBookmark,
        'Output folder access could not be restored. Add this book again.',
      );
      late final File output;
      var outputPublished = false;
      OutputFileReservation? reservation;
      try {
        final refreshed = outputAccess.refreshedBookmark;
        if (outputAccess.resolvedPath != job.outputDirectory ||
            (refreshed != null && refreshed != job.outputDirectoryBookmark)) {
          job = job.copyWith(
            outputDirectory: outputAccess.resolvedPath,
            outputDirectoryBookmark: refreshed ?? job.outputDirectoryBookmark,
          );
          if (!await _replace(job)) {
            return;
          }
        }
        if (job.outputPath != null) {
          final interruptedOutputPath = path.join(
            outputAccess.resolvedPath,
            path.basename(job.outputPath!),
          );
          await outputFileAllocator.cleanInterruptedReservation(
            outputPath: interruptedOutputPath,
            jobId: jobId,
          );
          job = job.copyWith(clearOutputPath: true);
          if (!await _replace(job)) {
            return;
          }
        }
        job = jobById(jobId);
        if (job == null || await _stopIfAbandoned(jobId)) {
          return;
        }
        reservation = await outputFileAllocator.reserve(
          directory: Directory(outputAccess.resolvedPath),
          sourcePath: job.sourcePath,
          targetLanguage: job.targetLanguage,
          jobId: jobId,
          outputExtension: job.outputExtension,
        );
        job = job.copyWith(outputPath: reservation.output.path);
        if (!await _replace(job)) {
          await _cancelOutputReservation(jobId, reservation);
          return;
        }
        if (await _stopIfAbandoned(jobId)) {
          await _cancelOutputReservation(jobId, reservation);
          return;
        }
        if (job.sourceFormat.requiresCalibre && job.preserveSourceFormat) {
          final translatedEpub = File(
            path.join(paths.workspaceFor(jobId).path, 'translated.epub'),
          );
          await session.repack(translatedEpub, keepOriginal: job.keepOriginal);
          if (await _stopIfAbandoned(jobId)) {
            await _cancelOutputReservation(jobId, reservation);
            return;
          }
          if (await _stopIfPaused(jobId)) {
            await _cancelOutputReservation(jobId, reservation);
            return;
          }
          job = jobById(jobId)!;
          await _replace(
            job.copyWith(status: TranslationJobStatus.convertingOutput),
          );
          await _log(
            jobId,
            'Converting translated EPUB to ${job.sourceFormat.name.toUpperCase()}.',
          );
          final installation = await _requireCalibre();
          final converted = File(
            path.join(
              paths.workspaceFor(jobId).path,
              'translated${job.sourceFormat.extension}',
            ),
          );
          await _bookConverter.convert(
            executable: installation.executable,
            input: translatedEpub,
            output: converted,
          );
          await converted.copy(reservation.staging.path);
        } else {
          await session.repack(
            reservation.staging,
            keepOriginal: job.keepOriginal,
          );
        }
        if (await _stopIfAbandoned(jobId)) {
          await _cancelOutputReservation(jobId, reservation);
          return;
        }
        if (await _stopIfPaused(jobId)) {
          await _cancelOutputReservation(jobId, reservation);
          return;
        }
        output = await reservation.publish();
        outputPublished = true;
        if (await _stopIfAbandoned(jobId)) {
          await _cancelOutputReservation(jobId, reservation, rollback: true);
          reservation = null;
          return;
        }
        job = jobById(jobId);
        if (job == null) {
          await reservation.rollback();
          reservation = null;
          return;
        }
        await _log(jobId, 'Output published to ${output.path}.');
        final completed = await _replace(
          job.copyWith(
            status: TranslationJobStatus.completed,
            outputPath: output.path,
            failedUnitIds: const {},
            clearError: true,
          ),
        );
        if (!completed) {
          await _cancelOutputReservation(jobId, reservation, rollback: true);
          reservation = null;
          await _stopIfAbandoned(jobId);
          return;
        }
        await reservation.releaseOwnership();
        reservation = null;
      } on Object {
        final failedReservation = reservation;
        if (failedReservation != null) {
          await _cancelOutputReservation(
            jobId,
            failedReservation,
            rollback: outputPublished,
          );
          reservation = null;
        }
        rethrow;
      } finally {
        await outputAccess.close();
      }
      try {
        await _deleteWorkspace(jobId);
      } on Object catch (error) {
        debugPrint('Unable to clean completed workspace: $error');
      }
      try {
        await desktopServices.notifyCompleted(
          jobId: jobId,
          outputPath: output.path,
        );
      } on Object catch (error) {
        debugPrint('Unable to show completion notification: $error');
      }
    } on Object catch (error) {
      final job = jobById(jobId);
      if (job != null &&
          job.status != TranslationJobStatus.abandoned &&
          job.status != TranslationJobStatus.paused) {
        await _replace(
          job.copyWith(
            status: TranslationJobStatus.waitingForAction,
            errorMessage: error.toString(),
          ),
        );
        await _log(jobId, 'Job failed: $error', level: JobLogLevel.error);
      }
    } finally {
      _cancellationTokens.remove(jobId);
      await _stopIfAbandoned(jobId);
    }
  }

  Future<EbookSession?> _prepareSession(String jobId) async {
    var job = jobById(jobId);
    if (job == null) return null;
    final workspace = paths.workspaceFor(jobId);
    final manifest = File(path.join(workspace.path, 'epub-workspace.json'));
    if (await manifest.exists()) {
      if (!await _replace(
        job.copyWith(status: TranslationJobStatus.unpacking),
      )) {
        return null;
      }
      await _log(jobId, 'Restoring the existing EPUB workspace.');
      return _codec.restore(workspace);
    }

    if (job.totalUnits != 0 ||
        job.completedUnitIds.isNotEmpty ||
        job.failedUnitIds.isNotEmpty) {
      job = job.copyWith(
        totalUnits: 0,
        completedUnitIds: const {},
        failedUnitIds: const {},
        clearError: true,
      );
      if (!await _replace(job)) return null;
    }

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
        if (!await _replace(job)) return null;
      }

      File epubInput = File(sourceAccess.resolvedPath);
      if (job.sourceFormat.requiresCalibre) {
        await workspace.create(recursive: true);
        final intermediate = File(path.join(workspace.path, 'input.epub'));
        if (!await intermediate.exists()) {
          if (!await _replace(
            job.copyWith(status: TranslationJobStatus.convertingInput),
          )) {
            return null;
          }
          await _log(
            jobId,
            'Converting ${job.sourceFormat.name.toUpperCase()} input to EPUB.',
          );
          final installation = await _requireCalibre();
          await _bookConverter.convert(
            executable: installation.executable,
            input: File(sourceAccess.resolvedPath),
            output: intermediate,
          );
          await _log(jobId, 'Input conversion completed.');
        } else {
          await _log(jobId, 'Reusing the converted EPUB input.');
        }
        epubInput = intermediate;
        if (await _stopIfAbandoned(jobId) || await _stopIfPaused(jobId)) {
          return null;
        }
      }

      job = jobById(jobId);
      if (job == null) return null;
      if (!await _replace(
        job.copyWith(status: TranslationJobStatus.unpacking),
      )) {
        return null;
      }
      await _log(jobId, 'Unpacking EPUB content.');
      final session = await _codec.unpack(epubInput, workspace: workspace);
      await _log(jobId, 'EPUB content unpacked.');
      return session;
    } finally {
      await sourceAccess.close();
    }
  }

  Future<CalibreInstallation> _requireCalibre() async {
    final existing = calibreInstallation;
    if (existing != null) return existing;
    final detected = await _bookConverter.detect(
      customExecutable: settings.calibreExecutable,
    );
    calibreInstallation = detected;
    if (detected == null) {
      throw const BookConversionException(
        'Calibre ebook-convert is required. Install it with: '
        '${CalibreService.installCommand}',
      );
    }
    return detected;
  }

  Future<bool> _stopIfPaused(String jobId) async {
    final current = jobById(jobId);
    if (!_pauseRequested.contains(jobId) &&
        current?.status != TranslationJobStatus.paused) {
      return false;
    }
    _pauseRequested.remove(jobId);
    if (current != null && current.status != TranslationJobStatus.paused) {
      await _log(jobId, 'Job paused.');
      await _replace(
        current.copyWith(status: TranslationJobStatus.paused, clearError: true),
      );
    }
    return true;
  }

  Future<void> _log(
    String jobId,
    String message, {
    JobLogLevel level = JobLogLevel.info,
  }) async {
    try {
      await jobLogRepository.append(
        jobId,
        message,
        level: level,
        secrets: settings.models.values.map((model) => model.apiKey),
      );
      notifyListeners();
    } on Object catch (error) {
      debugPrint('Unable to append job log for $jobId: $error');
    }
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

  Future<TranslationJob> _cleanInterruptedOutput(TranslationJob job) async {
    final outputPath = job.outputPath;
    if (outputPath == null) {
      return job;
    }
    final access = await _startRequiredAccess(
      job.outputDirectoryBookmark,
      'Output folder access could not be restored. Choose it again.',
    );
    try {
      final resolvedOutputPath = path.join(
        access.resolvedPath,
        path.basename(outputPath),
      );
      await outputFileAllocator.cleanInterruptedReservation(
        outputPath: resolvedOutputPath,
        jobId: job.id,
      );
      return job.copyWith(
        outputDirectory: access.resolvedPath,
        outputDirectoryBookmark:
            access.refreshedBookmark ?? job.outputDirectoryBookmark,
        clearOutputPath: true,
      );
    } finally {
      await access.close();
    }
  }

  Future<void> _cancelOutputReservation(
    String jobId,
    OutputFileReservation reservation, {
    bool rollback = false,
  }) async {
    if (rollback) {
      await reservation.rollback();
    } else {
      await reservation.cancel();
    }
    final current = jobById(jobId);
    if (current?.outputPath == reservation.output.path) {
      await _replace(current!.copyWith(clearOutputPath: true));
    }
  }

  Future<bool> _stopIfAbandoned(String jobId) async {
    if (!_abandonRequested.contains(jobId) &&
        jobById(jobId)?.status != TranslationJobStatus.abandoned) {
      return false;
    }
    try {
      await _deleteWorkspace(jobId);
    } on Object catch (error) {
      debugPrint('Unable to clean abandoned workspace: $error');
    } finally {
      _abandonRequested.remove(jobId);
    }
    return true;
  }

  Future<void> _deleteWorkspace(String jobId) async {
    for (final workspace in [
      paths.workspaceFor(jobId),
      paths.legacyWorkspaceFor(jobId),
    ]) {
      if (await workspace.exists()) {
        await workspace.delete(recursive: true);
      }
    }
  }

  Future<void> _migrateLegacyWorkspace(String jobId) async {
    final legacy = paths.legacyWorkspaceFor(jobId);
    final current = paths.workspaceFor(jobId);
    if (!await legacy.exists()) {
      return;
    }
    if (await current.exists()) {
      final currentManifest = File(
        path.join(current.path, 'epub-workspace.json'),
      );
      final legacyManifest = File(
        path.join(legacy.path, 'epub-workspace.json'),
      );
      if (await currentManifest.exists() || !await legacyManifest.exists()) {
        return;
      }
      await current.delete(recursive: true);
    }
    await current.parent.create(recursive: true);
    try {
      await legacy.rename(current.path);
      return;
    } on FileSystemException {
      // Application Support and Cache are normally on the same volume. Fall
      // back to a staged copy if the filesystem cannot rename between them.
    }

    final staging = Directory('${current.path}.migrating');
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
    try {
      await _copyDirectory(legacy, staging);
      if (await current.exists()) {
        await staging.delete(recursive: true);
        return;
      }
      await staging.rename(current.path);
      await legacy.delete(recursive: true);
    } on Object {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<void> _copyDirectory(Directory source, Directory destination) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      final targetPath = path.join(
        destination.path,
        path.basename(entity.path),
      );
      if (entity is File) {
        await entity.copy(targetPath);
      } else if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else {
        throw FileSystemException(
          'Unsupported entry in a Meow workspace.',
          entity.path,
        );
      }
    }
  }

  Future<bool> _replace(
    TranslationJob updated, {
    bool allowPausedTransition = false,
  }) async {
    final index = jobs.indexWhere((job) => job.id == updated.id);
    if (index < 0) {
      return false;
    }
    final current = jobs[index];
    if (current.status == TranslationJobStatus.abandoned &&
        updated.status != TranslationJobStatus.abandoned) {
      return false;
    }
    if (current.status == TranslationJobStatus.paused &&
        updated.status != TranslationJobStatus.paused &&
        updated.status != TranslationJobStatus.abandoned &&
        !allowPausedTransition) {
      return false;
    }
    jobs[index] = updated;
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    await jobRepository.save(jobs);
    notifyListeners();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

TranslationEngine createTranslationEngine(ModelSettings modelSettings) {
  return switch (modelSettings.provider) {
    TranslationProvider.deepseek => DeepSeekTranslationEngine(
      baseUrl: modelSettings.baseUrl,
      apiKey: modelSettings.apiKey,
      model: modelSettings.model,
    ),
    TranslationProvider.openAiCompatible => OpenAiCompatibleTranslationEngine(
      baseUrl: modelSettings.baseUrl,
      apiKey: modelSettings.apiKey,
      model: modelSettings.model,
    ),
    TranslationProvider.codexCli => CodexCliTranslationEngine(
      executable: modelSettings.executable,
      model: modelSettings.model,
    ),
  };
}
