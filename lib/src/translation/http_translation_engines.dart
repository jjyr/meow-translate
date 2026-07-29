import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'translation_engine.dart';
import 'translation_models.dart';

abstract base class HttpTranslationEngine implements TranslationEngine {
  HttpTranslationEngine({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
    this.streamIdleTimeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final String apiKey;
  final String model;
  final Duration requestTimeout;
  final Duration streamIdleTimeout;
  final http.Client _client;

  @override
  void close() => _client.close();

  Uri endpoint(String suffix) {
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$normalized/$suffix');
  }

  Map<String, String> get headers => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
  };

  String buildInput(TranslationRequest request) => request.unit.sourceText;

  String buildInstructions(TranslationRequest request) {
    final customPrompt = request.prompt.trim();
    return '''
$customPrompt

Target language: ${request.targetLanguage}

Response protocol (overrides any earlier output-format instruction):
Return only the translated plain text for the single source unit.
Do not return JSON, identifiers, labels, commentary, quotes, or Markdown fences.
''';
  }

  TranslatedUnit parseResult(String raw, TranslationRequest request) {
    if (raw.trim().isEmpty) {
      throw const TranslationEngineException(
        'The model returned an empty translation.',
      );
    }
    return TranslatedUnit(unitId: request.unit.id, text: raw);
  }

  Future<http.StreamedResponse> send(
    Uri uri,
    Map<String, Object?> payload,
    TranslationCancellationToken cancellationToken,
  ) async {
    cancellationToken.throwIfCancelled();
    if (apiKey.trim().isEmpty) {
      throw const TranslationEngineException('The API key is empty.');
    }
    if (model.trim().isEmpty) {
      throw const TranslationEngineException('The model name is empty.');
    }

    final request = http.Request('POST', uri)
      ..headers.addAll(headers)
      ..body = jsonEncode(payload);
    late final http.StreamedResponse response;
    try {
      response = await Future.any([
        _client.send(request),
        cancellationToken.whenCancelled.then<http.StreamedResponse>((_) {
          _client.close();
          throw const TranslationCancelledException();
        }),
      ]).timeout(requestTimeout);
    } on TimeoutException {
      _client.close();
      throw TranslationTimeoutException(
        'The model did not respond within ${requestTimeout.inSeconds} seconds.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await http.ByteStream(
        _monitorResponse(response.stream, cancellationToken),
      ).bytesToString();
      throw TranslationEngineException(
        'HTTP ${response.statusCode}: ${_shorten(body)}',
      );
    }
    return response;
  }

  Stream<List<int>> monitor(
    http.StreamedResponse response,
    TranslationCancellationToken cancellationToken,
  ) => _monitorResponse(response.stream, cancellationToken);

  Stream<List<int>> _monitorResponse(
    Stream<List<int>> source,
    TranslationCancellationToken cancellationToken,
  ) {
    late final StreamController<List<int>> controller;
    StreamSubscription<List<int>>? subscription;
    Timer? idleTimer;
    var finished = false;

    Future<void> finish({Object? error, StackTrace? stackTrace}) async {
      if (finished) {
        return;
      }
      finished = true;
      idleTimer?.cancel();
      final cancellation = subscription?.cancel();
      if (error != null) {
        controller.addError(error, stackTrace);
      }
      await controller.close();
      await cancellation;
    }

    void resetTimeout() {
      idleTimer?.cancel();
      idleTimer = Timer(streamIdleTimeout, () {
        final finishing = finish(
          error: TranslationTimeoutException(
            'The model stream was idle for '
            '${streamIdleTimeout.inSeconds} seconds.',
          ),
        );
        _client.close();
        unawaited(finishing);
      });
    }

    controller = StreamController<List<int>>(
      onListen: () {
        if (cancellationToken.isCancelled) {
          unawaited(finish(error: const TranslationCancelledException()));
          return;
        }
        resetTimeout();
        subscription = source.listen(
          (bytes) {
            if (finished) {
              return;
            }
            resetTimeout();
            controller.add(bytes);
          },
          onError: (Object error, StackTrace stackTrace) {
            unawaited(finish(error: error, stackTrace: stackTrace));
          },
          onDone: () => unawaited(finish()),
          cancelOnError: false,
        );
        unawaited(
          cancellationToken.whenCancelled.then((_) {
            final finishing = finish(
              error: const TranslationCancelledException(),
            );
            _client.close();
            return finishing;
          }),
        );
      },
      onCancel: () async {
        await finish();
      },
    );
    return controller.stream;
  }

  String _shorten(String value) {
    const maximumLength = 500;
    return value.length <= maximumLength
        ? value
        : '${value.substring(0, maximumLength)}…';
  }
}

base class OpenAiCompatibleTranslationEngine extends HttpTranslationEngine {
  OpenAiCompatibleTranslationEngine({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
    super.client,
    super.requestTimeout,
    super.streamIdleTimeout,
  });

  @override
  String get id => 'open_ai_compatible';

  @override
  Stream<TranslationEvent> translate(TranslationRequest request) async* {
    try {
      final response = await send(endpoint('chat/completions'), {
        'model': model,
        'stream': true,
        'temperature': 0.2,
        'messages': [
          {'role': 'system', 'content': buildInstructions(request)},
          {'role': 'user', 'content': buildInput(request)},
        ],
      }, request.cancellationToken);

      final buffer = StringBuffer();
      await for (final line in monitor(
        response,
        request.cancellationToken,
      ).transform(utf8.decoder).transform(const LineSplitter())) {
        request.cancellationToken.throwIfCancelled();
        if (!line.startsWith('data:')) {
          continue;
        }
        final data = line.substring(5).trim();
        if (data.isEmpty || data == '[DONE]') {
          continue;
        }
        final event = jsonDecode(data);
        if (event is! Map<String, dynamic>) {
          continue;
        }
        final choices = event['choices'];
        if (choices is! List<dynamic> || choices.isEmpty) {
          continue;
        }
        final choice = choices.first;
        if (choice is! Map<String, dynamic>) {
          continue;
        }
        final delta = choice['delta'];
        if (delta is! Map<String, dynamic> || delta['content'] is! String) {
          continue;
        }
        final text = delta['content'] as String;
        buffer.write(text);
        yield TranslationDelta(text);
      }
      yield TranslationCompleted(parseResult(buffer.toString(), request));
    } catch (error) {
      if (request.cancellationToken.isCancelled ||
          error is TranslationCancelledException) {
        yield const TranslationCancelled();
        return;
      }
      yield TranslationFailed(error.toString(), cause: error);
    }
  }
}

final class DeepSeekTranslationEngine
    extends OpenAiCompatibleTranslationEngine {
  DeepSeekTranslationEngine({
    required super.baseUrl,
    required super.apiKey,
    required super.model,
    super.client,
    super.requestTimeout,
    super.streamIdleTimeout,
  });

  @override
  String get id => 'deepseek';
}
