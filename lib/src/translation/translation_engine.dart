import 'translation_models.dart';

abstract interface class TranslationEngine {
  String get id;

  Stream<TranslationEvent> translate(TranslationRequest request);

  void close();
}

final class TranslationEngineException implements Exception {
  const TranslationEngineException(this.message);

  final String message;

  @override
  String toString() => 'TranslationEngineException: $message';
}
