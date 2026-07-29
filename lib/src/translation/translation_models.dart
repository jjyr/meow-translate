import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

final class TranslationFragment {
  const TranslationFragment({
    required this.id,
    required this.sourceText,
    required this.sourceHash,
    required this.startOffset,
    required this.endOffset,
  });

  final String id;
  final String sourceText;
  final String sourceHash;
  final int startOffset;
  final int endOffset;

  Map<String, Object> toPromptJson() => {'id': id, 'text': sourceText};
}

final class TranslationUnit {
  const TranslationUnit({
    required this.id,
    required this.resourcePath,
    required this.kind,
    required this.fragments,
  });

  final String id;
  final String resourcePath;
  final String kind;
  final List<TranslationFragment> fragments;

  String get sourceText =>
      fragments.map((fragment) => fragment.sourceText).join();

  Map<String, Object> toPromptJson() => {
    'id': id,
    'kind': kind,
    'fragments': fragments
        .map((fragment) => fragment.toPromptJson())
        .toList(growable: false),
  };
}

final class TranslationChunk {
  const TranslationChunk(this.units);

  final List<TranslationUnit> units;

  int get sourceCharacterCount =>
      units.fold(0, (total, unit) => total + unit.sourceText.length);
}

final class TranslationRequest {
  TranslationRequest({
    required this.chunk,
    required this.targetLanguage,
    required this.prompt,
    TranslationCancellationToken? cancellationToken,
  }) : cancellationToken = cancellationToken ?? TranslationCancellationToken();

  final TranslationChunk chunk;
  final String targetLanguage;
  final String prompt;
  final TranslationCancellationToken cancellationToken;
}

final class TranslationCancellationToken {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;

  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfCancelled() {
    if (isCancelled) {
      throw const TranslationCancelledException();
    }
  }
}

final class TranslatedUnit {
  const TranslatedUnit({required this.unitId, required this.fragments});

  final String unitId;
  final Map<String, String> fragments;
}

sealed class TranslationEvent {
  const TranslationEvent();
}

final class TranslationDelta extends TranslationEvent {
  const TranslationDelta(this.text);

  final String text;
}

final class TranslationCompleted extends TranslationEvent {
  const TranslationCompleted(this.units);

  final List<TranslatedUnit> units;
}

final class TranslationFailed extends TranslationEvent {
  const TranslationFailed(this.message, {this.cause});

  final String message;
  final Object? cause;
}

final class TranslationCancelled extends TranslationEvent {
  const TranslationCancelled();
}

final class TranslationCancelledException implements Exception {
  const TranslationCancelledException();

  @override
  String toString() => 'Translation was cancelled.';
}

final class TranslationTimeoutException implements Exception {
  const TranslationTimeoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

String stableTranslationId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 20);
