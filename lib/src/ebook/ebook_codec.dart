import 'dart:io';

import '../translation/translation_models.dart';

abstract interface class EbookCodec {
  String get format;

  bool supports(File source);

  Future<EbookSession> unpack(File source, {required Directory workspace});

  Future<EbookSession> restore(Directory workspace);
}

abstract interface class EbookSession {
  EbookPackageInfo get packageInfo;

  Directory get workspace;

  Stream<TranslationUnit> readTranslationUnits();

  Future<Set<String>> recordedTranslationUnitIds();

  Future<void> saveTranslation(
    TranslationUnit source,
    TranslatedUnit translation,
  );

  Future<File> repack(File output, {bool keepOriginal = false});
}

final class EbookPackageInfo {
  const EbookPackageInfo({
    required this.format,
    required this.title,
    required this.identifier,
    required this.sourcePath,
    required this.resourceCount,
  });

  final String format;
  final String title;
  final String identifier;
  final String sourcePath;
  final int resourceCount;
}

final class EbookCodecException implements Exception {
  const EbookCodecException(this.message);

  final String message;

  @override
  String toString() => 'EbookCodecException: $message';
}
