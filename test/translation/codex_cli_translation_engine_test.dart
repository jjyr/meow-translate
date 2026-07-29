import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/translation/codex_cli_translation_engine.dart';
import 'package:meow_translate/src/translation/translation_models.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'meow-codex-cli-test-',
    );
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('returns the Codex CLI stdout as translated text', () async {
    final executable = await _makeExecutable(
      temporaryDirectory,
      'success.sh',
      '''
#!/bin/sh
cat >/dev/null
printf "translated text"
''',
    );
    final engine = CodexCliTranslationEngine(
      executable: executable.path,
      model: 'test-model',
    );

    final events = await engine.translate(_request()).toList();

    expect(
      events.whereType<TranslationCompleted>().single.unit.text,
      'translated text',
    );
  });

  test('cancellation terminates the active Codex CLI process', () async {
    final marker = File('${temporaryDirectory.path}/started');
    final executable = await _makeExecutable(temporaryDirectory, 'stall.sh', '''
#!/bin/sh
echo started > "${marker.path}"
trap "exit 0" TERM
while :; do
  sleep 1
done
''');
    final token = TranslationCancellationToken();
    final engine = CodexCliTranslationEngine(
      executable: executable.path,
      model: 'test-model',
    );
    final eventsFuture = engine
        .translate(_request(cancellationToken: token))
        .toList();
    await _waitForFile(marker);

    token.cancel();
    final events = await eventsFuture.timeout(const Duration(seconds: 3));

    expect(events.whereType<TranslationCancelled>(), hasLength(1));
  });
}

TranslationRequest _request({
  TranslationCancellationToken? cancellationToken,
}) => TranslationRequest(
  unit: const TranslationUnit(
    id: 'unit-1',
    resourcePath: 'chapter.xhtml',
    kind: 'p',
    fragments: [
      TranslationFragment(
        id: 'fragment-1',
        sourceText: 'Hello',
        sourceHash: 'hash',
        startOffset: 0,
        endOffset: 5,
      ),
    ],
  ),
  targetLanguage: 'French',
  prompt: 'Translate.',
  cancellationToken: cancellationToken,
);

Future<File> _makeExecutable(
  Directory directory,
  String name,
  String contents,
) async {
  final file = File('${directory.path}/$name');
  await file.writeAsString(contents);
  await Process.run('chmod', ['755', file.path]);
  return file;
}

Future<void> _waitForFile(File file) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await file.exists()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('The fake Codex CLI did not start.');
}
