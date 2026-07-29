import '../settings/app_settings.dart';
import '../ebook/book_format.dart';

enum TranslationJobStatus {
  queued,
  convertingInput,
  unpacking,
  translating,
  repacking,
  convertingOutput,
  paused,
  waitingForAction,
  completed,
  abandoned,
}

extension TranslationJobStatusLabel on TranslationJobStatus {
  String get label => switch (this) {
    TranslationJobStatus.queued => 'Queued',
    TranslationJobStatus.convertingInput => 'Converting input',
    TranslationJobStatus.unpacking => 'Unpacking',
    TranslationJobStatus.translating => 'Translating',
    TranslationJobStatus.repacking => 'Repacking',
    TranslationJobStatus.convertingOutput => 'Converting output',
    TranslationJobStatus.paused => 'Paused',
    TranslationJobStatus.waitingForAction => 'Needs attention',
    TranslationJobStatus.completed => 'Completed',
    TranslationJobStatus.abandoned => 'Abandoned',
  };

  bool get isRunning => switch (this) {
    TranslationJobStatus.unpacking ||
    TranslationJobStatus.convertingInput ||
    TranslationJobStatus.translating ||
    TranslationJobStatus.repacking ||
    TranslationJobStatus.convertingOutput => true,
    _ => false,
  };
}

final class TranslationJob {
  const TranslationJob({
    required this.id,
    required this.sourcePath,
    required this.sourceBookmark,
    required this.outputDirectory,
    required this.outputDirectoryBookmark,
    required this.targetLanguage,
    required this.keepOriginal,
    required this.preserveSourceFormat,
    required this.provider,
    required this.createdAt,
    required this.status,
    required this.totalUnits,
    required this.completedUnitIds,
    required this.failedUnitIds,
    this.outputPath,
    this.errorMessage,
  });

  factory TranslationJob.fromJson(Map<String, dynamic> json) => TranslationJob(
    id: json['id'] as String,
    sourcePath: json['source_path'] as String,
    sourceBookmark: json['source_bookmark'] as String? ?? '',
    outputDirectory: json['output_directory'] as String,
    outputDirectoryBookmark: json['output_directory_bookmark'] as String? ?? '',
    targetLanguage: json['target_language'] as String,
    keepOriginal: json['keep_original'] as bool? ?? false,
    preserveSourceFormat: json['preserve_source_format'] as bool? ?? false,
    provider: _providerFromJson(json),
    createdAt: DateTime.parse(json['created_at'] as String),
    status: TranslationJobStatus.values.byName(json['status'] as String),
    totalUnits: json['total_units'] as int,
    completedUnitIds: (json['completed_unit_ids'] as List<dynamic>)
        .cast<String>()
        .toSet(),
    failedUnitIds: (json['failed_unit_ids'] as List<dynamic>)
        .cast<String>()
        .toSet(),
    outputPath: json['output_path'] as String?,
    errorMessage: json['error_message'] as String?,
  );

  final String id;
  final String sourcePath;
  final String sourceBookmark;
  final String outputDirectory;
  final String outputDirectoryBookmark;
  final String targetLanguage;
  final bool keepOriginal;
  final bool preserveSourceFormat;
  final TranslationProvider provider;
  final DateTime createdAt;
  final TranslationJobStatus status;
  final int totalUnits;
  final Set<String> completedUnitIds;
  final Set<String> failedUnitIds;
  final String? outputPath;
  final String? errorMessage;

  int get completedUnits => completedUnitIds.length;

  BookFormat get sourceFormat =>
      BookFormat.fromPath(sourcePath) ?? BookFormat.epub;

  String get outputExtension =>
      preserveSourceFormat ? sourceFormat.extension : BookFormat.epub.extension;

  double get progress =>
      totalUnits == 0 ? 0 : (completedUnits / totalUnits).clamp(0, 1);

  TranslationJob copyWith({
    String? sourcePath,
    String? sourceBookmark,
    String? outputDirectory,
    String? outputDirectoryBookmark,
    bool? keepOriginal,
    bool? preserveSourceFormat,
    TranslationJobStatus? status,
    int? totalUnits,
    Set<String>? completedUnitIds,
    Set<String>? failedUnitIds,
    String? outputPath,
    String? errorMessage,
    bool clearError = false,
    bool clearOutputPath = false,
  }) => TranslationJob(
    id: id,
    sourcePath: sourcePath ?? this.sourcePath,
    sourceBookmark: sourceBookmark ?? this.sourceBookmark,
    outputDirectory: outputDirectory ?? this.outputDirectory,
    outputDirectoryBookmark:
        outputDirectoryBookmark ?? this.outputDirectoryBookmark,
    targetLanguage: targetLanguage,
    keepOriginal: keepOriginal ?? this.keepOriginal,
    preserveSourceFormat: preserveSourceFormat ?? this.preserveSourceFormat,
    provider: provider,
    createdAt: createdAt,
    status: status ?? this.status,
    totalUnits: totalUnits ?? this.totalUnits,
    completedUnitIds: completedUnitIds ?? this.completedUnitIds,
    failedUnitIds: failedUnitIds ?? this.failedUnitIds,
    outputPath: clearOutputPath ? null : (outputPath ?? this.outputPath),
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'source_path': sourcePath,
    'source_bookmark': sourceBookmark,
    'output_directory': outputDirectory,
    'output_directory_bookmark': outputDirectoryBookmark,
    'target_language': targetLanguage,
    'keep_original': keepOriginal,
    'preserve_source_format': preserveSourceFormat,
    'provider': provider.name,
    'created_at': createdAt.toIso8601String(),
    'status': status.name,
    'total_units': totalUnits,
    'completed_unit_ids': completedUnitIds.toList()..sort(),
    'failed_unit_ids': failedUnitIds.toList()..sort(),
    'output_path': outputPath,
    'error_message': errorMessage,
  };
}

TranslationProvider _providerFromJson(Map<String, dynamic> json) {
  final provider = json['provider'];
  if (provider is String) {
    return TranslationProvider.values.byName(provider);
  }
  return TranslationProvider.deepseek;
}
