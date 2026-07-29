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
}

final class TranslationRequest {
  TranslationRequest({
    required this.unit,
    required this.targetLanguage,
    required this.prompt,
    TranslationCancellationToken? cancellationToken,
  }) : cancellationToken = cancellationToken ?? TranslationCancellationToken();

  final TranslationUnit unit;
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
  const TranslatedUnit({required this.unitId, required this.text});

  final String unitId;
  final String text;
}

sealed class TranslationEvent {
  const TranslationEvent();
}

final class TranslationDelta extends TranslationEvent {
  const TranslationDelta(this.text);

  final String text;
}

final class TranslationCompleted extends TranslationEvent {
  const TranslationCompleted(this.unit);

  final TranslatedUnit unit;
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
