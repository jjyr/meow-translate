import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/ebook_codec.dart';
import 'package:meow_translate/src/ebook/calibre_service.dart';
import 'package:meow_translate/src/jobs/job_controller.dart';
import 'package:meow_translate/src/jobs/job_log_repository.dart';
import 'package:meow_translate/src/jobs/job_repository.dart';
import 'package:meow_translate/src/jobs/output_file_allocator.dart';
import 'package:meow_translate/src/jobs/translation_job.dart';
import 'package:meow_translate/src/platform/desktop_services.dart';
import 'package:meow_translate/src/settings/app_settings.dart';
import 'package:meow_translate/src/settings/settings_repository.dart';
import 'package:meow_translate/src/storage/app_paths.dart';
import 'package:meow_translate/src/translation/translation_engine.dart';
import 'package:meow_translate/src/translation/translation_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const desktopChannel = MethodChannel('app.meow/desktop');
  late Directory temporaryDirectory;
  late AppPaths paths;
  late JobRepository jobRepository;
  late SettingsRepository settingsRepository;
  late Directory outputDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-job-controller-test-',
    );
    paths = AppPaths(
      supportDirectory: Directory('${temporaryDirectory.path}/support'),
      cacheDirectory: Directory('${temporaryDirectory.path}/cache'),
    );
    jobRepository = JobRepository(paths);
    settingsRepository = SettingsRepository(paths);
    outputDirectory = Directory('${temporaryDirectory.path}/output');
    await outputDirectory.create();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(desktopChannel, (call) async {
          switch (call.method) {
            case 'startAccessingBookmark':
              final arguments = call.arguments as Map<dynamic, dynamic>;
              final bookmark = arguments['bookmark'] as String;
              return {'token': 'token-$bookmark', 'path': bookmark};
            case 'stopAccessingBookmark':
            case 'notifyCompleted':
              return null;
            default:
              throw PlatformException(
                code: 'unexpected_method',
                message: call.method,
              );
          }
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(desktopChannel, null);
    try {
      await temporaryDirectory.delete(recursive: true);
    } on PathNotFoundException {
      // A controller cleanup may remove the last workspace concurrently.
    }
  });

  JobController createController({
    required _FakeSession session,
    TranslationEngine? engine,
    TranslationEngineFactory? translationEngineFactory,
    BookConverter? bookConverter,
    JobLogRepository? jobLogRepository,
  }) {
    assert(engine != null || translationEngineFactory != null);
    return JobController(
      paths: paths,
      settingsRepository: settingsRepository,
      jobRepository: jobRepository,
      desktopServices: DesktopServices(),
      maximumConcurrentJobs: 1,
      codec: _FakeCodec(session),
      bookConverter: bookConverter ?? _FakeBookConverter(),
      jobLogRepository: jobLogRepository,
      translationEngineFactory: translationEngineFactory ?? (_) => engine!,
    );
  }

  test(
    'missing workspace resets persisted progress and retranslates all units',
    () async {
      final session = _FakeSession(units: [_unit('unit-1'), _unit('unit-2')]);
      final engine = _FakeEngine();
      await jobRepository.save([
        _job(
          outputDirectory: outputDirectory,
          totalUnits: 2,
          completedUnitIds: const {'unit-1'},
          keepOriginal: true,
        ),
      ]);
      final controller = createController(session: session, engine: engine);

      await controller.initialize();
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.completed &&
            !paths.workspaceFor('job-1').existsSync(),
      );

      final completed = controller.jobById('job-1')!;
      expect(engine.requestedUnitIds, ['unit-1', 'unit-2']);
      expect(completed.completedUnitIds, {'unit-1', 'unit-2'});
      expect(await File(completed.outputPath!).readAsString(), 'unit-1,unit-2');
      expect(session.repackKeepOriginal, isTrue);
      expect(await paths.workspaceFor('job-1').exists(), isFalse);
      expect(
        paths.workspacesDirectory.path,
        startsWith(paths.supportDirectory.path),
      );
    },
  );

  test(
    'pause cancels the active unit and resume skips no completed work',
    () async {
      final session = _FakeSession(units: [_unit('unit-1'), _unit('unit-2')]);
      final engine = _PauseOnceEngine();
      await jobRepository.save([_job(outputDirectory: outputDirectory)]);
      final controller = createController(session: session, engine: engine);

      await controller.initialize();
      await engine.firstRequestStarted.future;
      await controller.pause('job-1');
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status == TranslationJobStatus.paused,
      );

      expect(controller.jobById('job-1')?.completedUnitIds, isEmpty);

      await controller.resume('job-1');
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.completed &&
            !controller.isJobRunning('job-1'),
      );

      expect(engine.requestedUnitIds, ['unit-1', 'unit-1', 'unit-2']);
      expect(controller.jobById('job-1')?.completedUnitIds, {
        'unit-1',
        'unit-2',
      });
    },
  );

  test(
    'retry processes only failed units and preserves successful units',
    () async {
      final session = _FakeSession(units: [_unit('unit-1'), _unit('unit-2')]);
      final engine = _FailOnceEngine('unit-1');
      await jobRepository.save([_job(outputDirectory: outputDirectory)]);
      final controller = createController(session: session, engine: engine);

      await controller.initialize();
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
            TranslationJobStatus.waitingForAction,
      );

      expect(controller.jobById('job-1')?.failedUnitIds, {'unit-1'});
      expect(controller.jobById('job-1')?.completedUnitIds, {'unit-2'});

      await controller.retry('job-1');
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.completed &&
            !controller.isJobRunning('job-1'),
      );

      expect(engine.requestedUnitIds, ['unit-1', 'unit-2', 'unit-1']);
      expect(controller.jobById('job-1')?.failedUnitIds, isEmpty);
    },
  );

  test('recreates the translation engine after a unit failure', () async {
    final requestedUnitIds = <String>[];
    final engines = <_SelectiveFailureEngine>[];
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(
      session: _FakeSession(units: [_unit('unit-1'), _unit('unit-2')]),
      translationEngineFactory: (_) {
        final engine = _SelectiveFailureEngine(
          failedUnitIds: engines.isEmpty ? const {'unit-1'} : const {},
          requestedUnitIds: requestedUnitIds,
        );
        engines.add(engine);
        return engine;
      },
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.waitingForAction &&
          !controller.isJobRunning('job-1'),
    );

    expect(requestedUnitIds, ['unit-1', 'unit-2']);
    expect(engines, hasLength(2));
    expect(engines.first.closed, isTrue);
    expect(controller.jobById('job-1')?.failedUnitIds, {'unit-1'});
    expect(controller.jobById('job-1')?.completedUnitIds, {'unit-2'});
  });

  test('stops after consecutive translation engine failures', () async {
    final requestedUnitIds = <String>[];
    var engineCount = 0;
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(
      session: _FakeSession(
        units: [
          _unit('unit-1'),
          _unit('unit-2'),
          _unit('unit-3'),
          _unit('unit-4'),
        ],
      ),
      translationEngineFactory: (_) {
        engineCount++;
        return _SelectiveFailureEngine(
          failedUnitIds: const {'unit-1', 'unit-2', 'unit-3', 'unit-4'},
          requestedUnitIds: requestedUnitIds,
        );
      },
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.waitingForAction &&
          !controller.isJobRunning('job-1'),
    );

    final failed = controller.jobById('job-1')!;
    expect(requestedUnitIds, ['unit-1', 'unit-2']);
    expect(engineCount, 2);
    expect(failed.failedUnitIds, {'unit-1', 'unit-2'});
    expect(failed.errorMessage, contains('repeated engine failures'));
  });

  test('successful units reset the consecutive failure breaker', () async {
    final requestedUnitIds = <String>[];
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(
      session: _FakeSession(
        units: [
          _unit('unit-1'),
          _unit('unit-2'),
          _unit('unit-3'),
          _unit('unit-4'),
        ],
      ),
      translationEngineFactory: (_) => _SelectiveFailureEngine(
        failedUnitIds: const {'unit-1', 'unit-3'},
        requestedUnitIds: requestedUnitIds,
      ),
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.waitingForAction &&
          !controller.isJobRunning('job-1'),
    );

    expect(requestedUnitIds, ['unit-1', 'unit-2', 'unit-3', 'unit-4']);
    expect(controller.jobById('job-1')?.failedUnitIds, {'unit-1', 'unit-3'});
    expect(controller.jobById('job-1')?.completedUnitIds, {'unit-2', 'unit-4'});
  });

  test('a queued pause survives an in-flight preparation snapshot', () async {
    final sourceAccessStarted = Completer<void>();
    final allowSourceAccess = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(desktopChannel, (call) async {
          switch (call.method) {
            case 'startAccessingBookmark':
              if (!sourceAccessStarted.isCompleted) {
                sourceAccessStarted.complete();
              }
              await allowSourceAccess.future;
              final arguments = call.arguments as Map<dynamic, dynamic>;
              final bookmark = arguments['bookmark'] as String;
              return {'token': 'token-$bookmark', 'path': bookmark};
            case 'stopAccessingBookmark':
            case 'notifyCompleted':
              return null;
            default:
              throw PlatformException(
                code: 'unexpected_method',
                message: call.method,
              );
          }
        });
    final engine = _FakeEngine();
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(
      session: _FakeSession(units: [_unit('unit-1')]),
      engine: engine,
    );

    await controller.initialize();
    await sourceAccessStarted.future;
    expect(controller.jobById('job-1')?.status, TranslationJobStatus.queued);
    await controller.pause('job-1');
    allowSourceAccess.complete();
    await _waitUntil(() => !controller.isJobRunning('job-1'));

    expect(controller.jobById('job-1')?.status, TranslationJobStatus.paused);
    expect(engine.requestedUnitIds, isEmpty);
  });

  test('job log failures do not block the failure state transition', () async {
    final engine = _FakeEngine();
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(
      session: _FakeSession(
        units: [_unit('unit-1')],
        repackError: StateError('simulated repack failure'),
      ),
      engine: engine,
      jobLogRepository: _ThrowingJobLogRepository(paths),
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.waitingForAction &&
          !controller.isJobRunning('job-1'),
    );

    expect(
      controller.jobById('job-1')?.errorMessage,
      contains('simulated repack failure'),
    );
  });

  test('an older Calibre check cannot clear a newer in-flight check', () async {
    final converter = _ControlledBookConverter();
    final controller = createController(
      session: _FakeSession(units: const []),
      engine: _FakeEngine(),
      bookConverter: converter,
    );
    controller.calibreInstallation = const CalibreInstallation(
      executable: '/initial/ebook-convert',
      version: 'initial',
    );

    final older = controller.refreshCalibre(
      customExecutable: '/older/ebook-convert',
    );
    final newer = controller.refreshCalibre(
      customExecutable: '/newer/ebook-convert',
    );
    converter.complete(
      '/older/ebook-convert',
      const CalibreInstallation(
        executable: '/older/ebook-convert',
        version: 'older',
      ),
    );
    await older;

    expect(controller.checkingCalibre, isTrue);
    expect(
      controller.calibreInstallation?.executable,
      '/initial/ebook-convert',
    );

    converter.complete(
      '/newer/ebook-convert',
      const CalibreInstallation(
        executable: '/newer/ebook-convert',
        version: 'newer',
      ),
    );
    await newer;

    expect(controller.checkingCalibre, isFalse);
    expect(controller.calibreInstallation?.executable, '/newer/ebook-convert');
  });

  test(
    'a slower older Calibre check cannot overwrite the latest result',
    () async {
      final converter = _ControlledBookConverter();
      final controller = createController(
        session: _FakeSession(units: const []),
        engine: _FakeEngine(),
        bookConverter: converter,
      );

      final older = controller.refreshCalibre(
        customExecutable: '/older/ebook-convert',
      );
      final newer = controller.refreshCalibre(
        customExecutable: '/newer/ebook-convert',
      );
      converter.complete(
        '/newer/ebook-convert',
        const CalibreInstallation(
          executable: '/newer/ebook-convert',
          version: 'newer',
        ),
      );
      await newer;
      converter.complete(
        '/older/ebook-convert',
        const CalibreInstallation(
          executable: '/older/ebook-convert',
          version: 'older',
        ),
      );
      await older;

      expect(controller.checkingCalibre, isFalse);
      expect(
        controller.calibreInstallation?.executable,
        '/newer/ebook-convert',
      );
    },
  );

  test('MOBI jobs convert input and preserve source output format', () async {
    final session = _FakeSession(units: [_unit('unit-1')]);
    final converter = _FakeBookConverter();
    await jobRepository.save([
      _job(
        outputDirectory: outputDirectory,
        sourcePath: '/books/book.mobi',
        preserveSourceFormat: true,
      ),
    ]);
    final controller = createController(
      session: session,
      engine: _FakeEngine(),
      bookConverter: converter,
    );

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.completed &&
          !controller.isJobRunning('job-1'),
    );

    final completed = controller.jobById('job-1')!;
    expect(converter.conversions, hasLength(2));
    expect(converter.conversions.first.$1, endsWith('.mobi'));
    expect(converter.conversions.first.$2, endsWith('input.epub'));
    expect(converter.conversions.last.$1, endsWith('translated.epub'));
    expect(converter.conversions.last.$2, endsWith('.mobi'));
    expect(completed.outputPath, endsWith('.mobi'));
    expect(await controller.readJobLog('job-1'), isNotEmpty);
  });

  test(
    'MOBI jobs report the Calibre install command when unavailable',
    () async {
      await jobRepository.save([
        _job(outputDirectory: outputDirectory, sourcePath: '/books/book.mobi'),
      ]);
      final controller = createController(
        session: _FakeSession(units: [_unit('unit-1')]),
        engine: _FakeEngine(),
        bookConverter: _MissingBookConverter(),
      );

      await controller.initialize();
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.waitingForAction &&
            !controller.isJobRunning('job-1'),
      );

      expect(
        controller.jobById('job-1')?.errorMessage,
        contains('brew install --cask calibre'),
      );
    },
  );

  test('paused jobs remain paused after application restart', () async {
    await jobRepository.save([
      _job(
        outputDirectory: outputDirectory,
      ).copyWith(status: TranslationJobStatus.paused),
    ]);
    final controller = createController(
      session: _FakeSession(units: [_unit('unit-1')]),
      engine: _FakeEngine(),
    );

    await controller.initialize();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(controller.jobById('job-1')?.status, TranslationJobStatus.paused);
  });

  test(
    'retranslate all clears progress and requests every unit again',
    () async {
      final session = _FakeSession(units: [_unit('unit-1'), _unit('unit-2')]);
      final engine = _FakeEngine();
      await jobRepository.save([_job(outputDirectory: outputDirectory)]);
      final controller = createController(session: session, engine: engine);

      await controller.initialize();
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.completed &&
            !controller.isJobRunning('job-1'),
      );
      await controller.retranslateAll('job-1');
      await _waitUntil(
        () =>
            controller.jobById('job-1')?.status ==
                TranslationJobStatus.completed &&
            engine.requestedUnitIds.length == 4 &&
            !controller.isJobRunning('job-1'),
      );

      expect(engine.requestedUnitIds, ['unit-1', 'unit-2', 'unit-1', 'unit-2']);
      expect(controller.jobById('job-1')?.completedUnitIds, {
        'unit-1',
        'unit-2',
      });
    },
  );

  test('cancel during translation persistence remains abandoned', () async {
    final saveStarted = Completer<void>();
    final allowSave = Completer<void>();
    final session = _FakeSession(
      units: [_unit('unit-1')],
      saveStarted: saveStarted,
      allowSave: allowSave,
    );
    final engine = _FakeEngine();
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(session: session, engine: engine);

    await controller.initialize();
    await saveStarted.future;
    await controller.abandon('job-1');
    allowSave.complete();
    await engine.closed.future;
    await _waitUntil(() => !paths.workspaceFor('job-1').existsSync());

    expect(controller.jobById('job-1')?.status, TranslationJobStatus.abandoned);
    expect(outputDirectory.listSync().whereType<File>(), isEmpty);
  });

  test('missing transcript entries reset persisted completion state', () async {
    final workspace = paths.workspaceFor('job-1');
    await workspace.create(recursive: true);
    await File(
      '${workspace.path}/epub-workspace.json',
    ).writeAsString('fake manifest');
    final session = _FakeSession(
      units: [_unit('unit-1'), _unit('unit-2')],
      recordedUnitIds: const {},
    );
    final engine = _FakeEngine();
    await jobRepository.save([
      _job(
        outputDirectory: outputDirectory,
        totalUnits: 2,
        completedUnitIds: const {'unit-1'},
      ),
    ]);
    final controller = createController(session: session, engine: engine);

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
              TranslationJobStatus.completed &&
          !workspace.existsSync(),
    );

    expect(engine.requestedUnitIds, ['unit-1', 'unit-2']);
    expect(controller.jobById('job-1')?.completedUnitIds, {'unit-1', 'unit-2'});
  });

  test('unfinished legacy cache workspace is migrated and resumed', () async {
    final legacyWorkspace = paths.legacyWorkspaceFor('job-1');
    final incompleteCurrentWorkspace = paths.workspaceFor('job-1');
    await legacyWorkspace.create(recursive: true);
    await incompleteCurrentWorkspace.create(recursive: true);
    await File(
      '${incompleteCurrentWorkspace.path}/incomplete',
    ).writeAsString('stale');
    await File(
      '${legacyWorkspace.path}/epub-workspace.json',
    ).writeAsString('fake manifest');
    final session = _FakeSession(
      units: [_unit('unit-1'), _unit('unit-2')],
      recordedUnitIds: const {'unit-1'},
    );
    final engine = _FakeEngine();
    await jobRepository.save([
      _job(
        outputDirectory: outputDirectory,
        totalUnits: 2,
        completedUnitIds: const {'unit-1'},
      ),
    ]);
    final controller = createController(session: session, engine: engine);

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status == TranslationJobStatus.completed,
    );

    expect(engine.requestedUnitIds, ['unit-2']);
    expect(session.savedUnitIds, ['unit-2']);
    expect(await legacyWorkspace.exists(), isFalse);
  });

  test('repack failure clears the cancelled output reservation path', () async {
    final session = _FakeSession(
      units: [_unit('unit-1')],
      repackError: StateError('repack failed'),
    );
    final engine = _FakeEngine();
    await jobRepository.save([_job(outputDirectory: outputDirectory)]);
    final controller = createController(session: session, engine: engine);

    await controller.initialize();
    await _waitUntil(
      () =>
          controller.jobById('job-1')?.status ==
          TranslationJobStatus.waitingForAction,
    );
    await engine.closed.future;
    await _waitUntilAsync(() async {
      final stored = (await jobRepository.load()).single;
      return stored.status == TranslationJobStatus.waitingForAction &&
          stored.outputPath == null;
    });

    expect(controller.jobById('job-1')?.outputPath, isNull);
    expect(outputDirectory.listSync(), isEmpty);
  });

  test(
    'cancel during repack removes staging and never publishes output',
    () async {
      final repackStarted = Completer<void>();
      final allowRepack = Completer<void>();
      final session = _FakeSession(
        units: [_unit('unit-1')],
        repackStarted: repackStarted,
        allowRepack: allowRepack,
      );
      await jobRepository.save([_job(outputDirectory: outputDirectory)]);
      final controller = createController(
        session: session,
        engine: _FakeEngine(),
      );

      await controller.initialize();
      await repackStarted.future;
      await controller.abandon('job-1');
      allowRepack.complete();
      await _waitUntil(
        () =>
            !paths.workspaceFor('job-1').existsSync() &&
            outputDirectory.listSync().isEmpty,
      );

      expect(
        controller.jobById('job-1')?.status,
        TranslationJobStatus.abandoned,
      );
      expect(controller.jobById('job-1')?.outputPath, isNull);
      expect(outputDirectory.listSync(), isEmpty);
    },
  );

  test(
    'startup cleans an interrupted output only when its marker is owned',
    () async {
      const allocator = OutputFileAllocator();
      final reservation = await allocator.reserve(
        directory: outputDirectory,
        sourcePath: '/books/book.epub',
        targetLanguage: 'English',
        jobId: 'job-1',
      );
      await reservation.staging.writeAsString('complete but interrupted');
      await reservation.publish();
      expect(await reservation.output.exists(), isTrue);
      await jobRepository.save([
        _job(outputDirectory: outputDirectory).copyWith(
          status: TranslationJobStatus.repacking,
          outputPath: reservation.output.path,
        ),
      ]);
      final controller = createController(
        session: _FakeSession(units: [_unit('unit-1')]),
        engine: _FakeEngine(),
      );

      await controller.initialize();

      final recovered = controller.jobById('job-1')!;
      expect(recovered.status, TranslationJobStatus.waitingForAction);
      expect(recovered.outputPath, isNull);
      expect(await reservation.staging.exists(), isFalse);
      expect(await reservation.output.exists(), isFalse);
      expect(outputDirectory.listSync(), isEmpty);
    },
  );

  test(
    'startup removes current and legacy workspaces for completed jobs',
    () async {
      final currentWorkspace = paths.workspaceFor('job-1');
      final legacyWorkspace = paths.legacyWorkspaceFor('job-1');
      await currentWorkspace.create(recursive: true);
      await legacyWorkspace.create(recursive: true);
      await jobRepository.save([
        _job(
          outputDirectory: outputDirectory,
        ).copyWith(status: TranslationJobStatus.completed),
      ]);
      final controller = createController(
        session: _FakeSession(units: const <TranslationUnit>[]),
        engine: _FakeEngine(),
      );

      await controller.initialize();

      expect(await currentWorkspace.exists(), isFalse);
      expect(await legacyWorkspace.exists(), isFalse);
      expect(
        controller.jobById('job-1')?.status,
        TranslationJobStatus.completed,
      );
    },
  );
}

TranslationJob _job({
  required Directory outputDirectory,
  String sourcePath = '/books/book.epub',
  int totalUnits = 0,
  Set<String> completedUnitIds = const {},
  bool keepOriginal = false,
  bool preserveSourceFormat = false,
}) => TranslationJob(
  id: 'job-1',
  sourcePath: sourcePath,
  sourceBookmark: sourcePath,
  outputDirectory: outputDirectory.path,
  outputDirectoryBookmark: outputDirectory.path,
  targetLanguage: 'English',
  keepOriginal: keepOriginal,
  preserveSourceFormat: preserveSourceFormat,
  provider: TranslationProvider.deepseek,
  createdAt: DateTime.utc(2026),
  status: TranslationJobStatus.queued,
  totalUnits: totalUnits,
  completedUnitIds: completedUnitIds,
  failedUnitIds: const {},
);

TranslationUnit _unit(String id) => TranslationUnit(
  id: id,
  resourcePath: 'chapter.xhtml',
  kind: 'p',
  fragments: [
    TranslationFragment(
      id: 'fragment-$id',
      sourceText: id,
      sourceHash: 'hash-$id',
      startOffset: 0,
      endOffset: id.length,
    ),
  ],
);

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the job state to change.');
}

Future<void> _waitUntilAsync(Future<bool> Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for the persisted job state to change.');
}

final class _FakeCodec implements EbookCodec {
  const _FakeCodec(this.session);

  final _FakeSession session;

  @override
  String get format => 'epub';

  @override
  bool supports(File source) => true;

  @override
  Future<EbookSession> unpack(
    File source, {
    required Directory workspace,
  }) async {
    session.currentWorkspace = workspace;
    await workspace.create(recursive: true);
    await File(
      '${workspace.path}/epub-workspace.json',
    ).writeAsString('fake manifest');
    return session;
  }

  @override
  Future<EbookSession> restore(Directory workspace) async {
    session.currentWorkspace = workspace;
    return session;
  }
}

final class _FakeSession implements EbookSession {
  _FakeSession({
    required this.units,
    Set<String>? recordedUnitIds,
    this.saveStarted,
    this.allowSave,
    this.repackStarted,
    this.allowRepack,
    this.repackError,
  }) : recordedUnitIds = recordedUnitIds ?? {};

  final List<TranslationUnit> units;
  final Set<String> recordedUnitIds;
  final Completer<void>? saveStarted;
  final Completer<void>? allowSave;
  final Completer<void>? repackStarted;
  final Completer<void>? allowRepack;
  final Object? repackError;
  final List<String> savedUnitIds = [];
  bool? repackKeepOriginal;
  Directory currentWorkspace = Directory.systemTemp;

  @override
  EbookPackageInfo get packageInfo => const EbookPackageInfo(
    format: 'epub',
    title: 'Test book',
    identifier: 'test-book',
    sourcePath: '/books/book.epub',
    resourceCount: 1,
  );

  @override
  Directory get workspace => currentWorkspace;

  @override
  Stream<TranslationUnit> readTranslationUnits() => Stream.fromIterable(units);

  @override
  Future<Set<String>> recordedTranslationUnitIds() async => {
    ...recordedUnitIds,
    ...savedUnitIds,
  };

  @override
  Future<void> saveTranslation(
    TranslationUnit source,
    TranslatedUnit translation,
  ) async {
    if (saveStarted != null && !saveStarted!.isCompleted) {
      saveStarted!.complete();
    }
    await allowSave?.future;
    savedUnitIds.add(source.id);
  }

  @override
  Future<File> repack(File output, {bool keepOriginal = false}) async {
    repackKeepOriginal = keepOriginal;
    if (repackStarted != null && !repackStarted!.isCompleted) {
      repackStarted!.complete();
    }
    await output.writeAsString('partial');
    if (repackError != null) {
      throw repackError!;
    }
    await allowRepack?.future;
    await output.writeAsString(savedUnitIds.join(','));
    return output;
  }
}

final class _FakeEngine implements TranslationEngine {
  final List<String> requestedUnitIds = [];
  final Completer<void> closed = Completer<void>();

  @override
  String get id => 'fake';

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requestedUnitIds.add(request.unit.id);
    yield TranslationCompleted(
      TranslatedUnit(
        unitId: request.unit.id,
        text: 'translated ${request.unit.sourceText}',
      ),
    );
  }

  @override
  void close() {
    if (!closed.isCompleted) {
      closed.complete();
    }
  }
}

final class _PauseOnceEngine implements TranslationEngine {
  final Completer<void> firstRequestStarted = Completer<void>();
  final List<String> requestedUnitIds = [];
  var _pausedOnce = false;

  @override
  String get id => 'pause-once';

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requestedUnitIds.add(request.unit.id);
    if (!_pausedOnce) {
      _pausedOnce = true;
      firstRequestStarted.complete();
      await request.cancellationToken.whenCancelled;
      yield const TranslationCancelled();
      return;
    }
    yield TranslationCompleted(
      TranslatedUnit(
        unitId: request.unit.id,
        text: 'translated ${request.unit.sourceText}',
      ),
    );
  }

  @override
  void close() {}
}

final class _FailOnceEngine implements TranslationEngine {
  _FailOnceEngine(this.unitToFail);

  final String unitToFail;
  final List<String> requestedUnitIds = [];
  var _failed = false;

  @override
  String get id => 'fail-once';

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requestedUnitIds.add(request.unit.id);
    if (!_failed && request.unit.id == unitToFail) {
      _failed = true;
      yield const TranslationFailed('simulated failure');
      return;
    }
    yield TranslationCompleted(
      TranslatedUnit(
        unitId: request.unit.id,
        text: 'translated ${request.unit.sourceText}',
      ),
    );
  }

  @override
  void close() {}
}

final class _SelectiveFailureEngine implements TranslationEngine {
  _SelectiveFailureEngine({
    required this.failedUnitIds,
    required this.requestedUnitIds,
  });

  final Set<String> failedUnitIds;
  final List<String> requestedUnitIds;
  bool closed = false;

  @override
  String get id => 'selective-failure';

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    requestedUnitIds.add(request.unit.id);
    if (failedUnitIds.contains(request.unit.id)) {
      yield const TranslationFailed('simulated engine failure');
      return;
    }
    yield TranslationCompleted(
      TranslatedUnit(
        unitId: request.unit.id,
        text: 'translated ${request.unit.sourceText}',
      ),
    );
  }

  @override
  void close() {
    closed = true;
  }
}

final class _ThrowingJobLogRepository extends JobLogRepository {
  _ThrowingJobLogRepository(super.paths);

  @override
  Future<void> append(
    String jobId,
    String message, {
    JobLogLevel level = JobLogLevel.info,
    Iterable<String> secrets = const [],
  }) async {
    throw const FileSystemException('simulated read-only log directory');
  }
}

final class _ControlledBookConverter implements BookConverter {
  final Map<String, Completer<CalibreInstallation?>> _responses = {};

  @override
  Future<CalibreInstallation?> detect({String customExecutable = ''}) =>
      _responses
          .putIfAbsent(
            customExecutable,
            () => Completer<CalibreInstallation?>(),
          )
          .future;

  void complete(String executable, CalibreInstallation? installation) {
    _responses[executable]!.complete(installation);
  }

  @override
  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  }) => throw UnsupportedError('Conversion is not used by this test.');
}

final class _FakeBookConverter implements BookConverter {
  final List<(String, String)> conversions = [];

  @override
  Future<CalibreInstallation?> detect({String customExecutable = ''}) async =>
      const CalibreInstallation(
        executable: '/fake/ebook-convert',
        version: 'ebook-convert test',
      );

  @override
  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  }) async {
    conversions.add((input.path, output.path));
    await output.parent.create(recursive: true);
    await output.writeAsString('converted');
  }
}

final class _MissingBookConverter implements BookConverter {
  @override
  Future<CalibreInstallation?> detect({String customExecutable = ''}) async =>
      null;

  @override
  Future<void> convert({
    required String executable,
    required File input,
    required File output,
  }) => throw StateError('convert should not be called');
}
