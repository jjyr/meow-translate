import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/ebook_codec.dart';
import 'package:meow_translate/src/jobs/job_controller.dart';
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
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  JobController createController({
    required _FakeSession session,
    required _FakeEngine engine,
  }) {
    return JobController(
      paths: paths,
      settingsRepository: settingsRepository,
      jobRepository: jobRepository,
      desktopServices: DesktopServices(),
      maximumConcurrentJobs: 1,
      codec: _FakeCodec(session),
      translationEngineFactory: (_) => engine,
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
  int totalUnits = 0,
  Set<String> completedUnitIds = const {},
  bool keepOriginal = false,
}) => TranslationJob(
  id: 'job-1',
  sourcePath: '/books/book.epub',
  sourceBookmark: '/books/book.epub',
  outputDirectory: outputDirectory.path,
  outputDirectoryBookmark: outputDirectory.path,
  targetLanguage: 'English',
  keepOriginal: keepOriginal,
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
