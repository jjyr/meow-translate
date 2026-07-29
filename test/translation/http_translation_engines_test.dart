import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meow_translate/src/translation/http_translation_engines.dart';
import 'package:meow_translate/src/translation/translation_models.dart';

void main() {
  final unit = TranslationUnit(
    id: 'unit-1',
    resourcePath: 'chapter.xhtml',
    kind: 'p',
    fragments: const [
      TranslationFragment(
        id: 'f0',
        sourceText: 'Hello',
        sourceHash: 'hash',
        startOffset: 0,
        endOffset: 5,
      ),
    ],
  );
  late TranslationRequest request;

  setUp(() {
    request = TranslationRequest(
      unit: unit,
      targetLanguage: 'Simplified Chinese',
      prompt: 'Translate.',
    );
  });

  test('DeepSeek engine streams plain-text translation deltas', () async {
    const translation = '你好，世界';
    final split = translation.length ~/ 2;
    final client = _SseClient([
      _deepSeekDelta(translation.substring(0, split)),
      _deepSeekDelta(translation.substring(split)),
      'data: [DONE]',
    ]);
    final engine = DeepSeekTranslationEngine(
      baseUrl: 'https://api.deepseek.test/v1/',
      apiKey: 'secret',
      model: 'deepseek-chat',
      client: client,
    );

    final events = await engine.translate(request).toList();

    expect(events.whereType<TranslationDelta>(), hasLength(2));
    final completed = events.whereType<TranslationCompleted>().single;
    expect(completed.unit.unitId, 'unit-1');
    expect(completed.unit.text, translation);
    expect(client.request.url.toString(), endsWith('/v1/chat/completions'));
    expect(client.request.headers['Authorization'], 'Bearer secret');
    final body = jsonDecode(client.request.body) as Map<String, dynamic>;
    expect(body['stream'], isTrue);
    final messages = body['messages'] as List<dynamic>;
    expect((messages.last as Map<String, dynamic>)['content'], unit.sourceText);
    expect(
      (messages.first as Map<String, dynamic>)['content'],
      contains('Return only the translated plain text'),
    );
    expect(
      (messages.first as Map<String, dynamic>)['content'],
      contains('Target language: Simplified Chinese'),
    );
  });

  test('Codex engine parses Responses API output text events', () async {
    const translation = '你好';
    final client = _SseClient([
      'data: ${jsonEncode({'type': 'response.output_text.delta', 'delta': translation})}',
      'data: ${jsonEncode({'type': 'response.completed'})}',
    ]);
    final engine = CodexTranslationEngine(
      baseUrl: 'https://api.openai.test/v1',
      apiKey: 'secret',
      model: 'codex-mini-latest',
      client: client,
    );

    final events = await engine.translate(request).toList();

    expect(events.whereType<TranslationDelta>().single.text, translation);
    expect(
      events.whereType<TranslationCompleted>().single.unit.text,
      translation,
    );
    expect(client.request.url.toString(), endsWith('/v1/responses'));
    final body = jsonDecode(client.request.body) as Map<String, dynamic>;
    expect(body['instructions'], contains('Translate.'));
    expect(
      body['instructions'],
      contains('Return only the translated plain text'),
    );
    expect(body['input'], unit.sourceText);
    expect(body['stream'], isTrue);
  });

  test(
    'engine treats model output as opaque text instead of parsing JSON',
    () async {
      const translation = '{"translated":"你好"}';
      final client = _SseClient([_deepSeekDelta(translation), 'data: [DONE]']);
      final engine = DeepSeekTranslationEngine(
        baseUrl: 'https://api.deepseek.test/v1',
        apiKey: 'secret',
        model: 'deepseek-chat',
        client: client,
      );

      final events = await engine.translate(request).toList();

      expect(events.whereType<TranslationFailed>(), isEmpty);
      expect(
        events.whereType<TranslationCompleted>().single.unit.text,
        translation,
      );
    },
  );

  test('cancellation stops a request that has not received headers', () async {
    final client = _StallingClient();
    final token = TranslationCancellationToken();
    final engine = DeepSeekTranslationEngine(
      baseUrl: 'https://api.deepseek.test/v1',
      apiKey: 'secret',
      model: 'deepseek-chat',
      client: client,
      requestTimeout: const Duration(seconds: 5),
    );
    final eventsFuture = engine
        .translate(
          TranslationRequest(
            unit: unit,
            targetLanguage: 'Simplified Chinese',
            prompt: 'Translate.',
            cancellationToken: token,
          ),
        )
        .toList();
    await client.sent;

    token.cancel();
    final events = await eventsFuture.timeout(const Duration(seconds: 1));

    expect(events.whereType<TranslationCancelled>(), hasLength(1));
    expect(client.closed, isTrue);
  });

  test('an idle SSE stream fails with a bounded timeout', () async {
    final client = _IdleSseClient();
    final engine = DeepSeekTranslationEngine(
      baseUrl: 'https://api.deepseek.test/v1',
      apiKey: 'secret',
      model: 'deepseek-chat',
      client: client,
      streamIdleTimeout: const Duration(milliseconds: 20),
    );

    final events = await engine
        .translate(request)
        .toList()
        .timeout(const Duration(seconds: 1));

    final failure = events.whereType<TranslationFailed>().single;
    expect(failure.cause, isA<TranslationTimeoutException>());
    expect(client.closed, isTrue);
  });
}

String _deepSeekDelta(String content) =>
    'data: ${jsonEncode({
      'choices': [
        {
          'delta': {'content': content},
        },
      ],
    })}';

final class _SseClient extends http.BaseClient {
  _SseClient(this.lines);

  final List<String> lines;
  late http.Request request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest value) async {
    request = value as http.Request;
    return http.StreamedResponse(
      Stream.value(utf8.encode('${lines.join('\n')}\n')),
      200,
    );
  }
}

final class _StallingClient extends http.BaseClient {
  final Completer<void> _sent = Completer<void>();
  final Completer<http.StreamedResponse> _response =
      Completer<http.StreamedResponse>();
  bool closed = false;

  Future<void> get sent => _sent.future;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _sent.complete();
    return _response.future;
  }

  @override
  void close() {
    closed = true;
  }
}

final class _IdleSseClient extends http.BaseClient {
  final StreamController<List<int>> _stream = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(_stream.stream, 200);

  @override
  void close() {
    closed = true;
    unawaited(_stream.close());
  }
}
