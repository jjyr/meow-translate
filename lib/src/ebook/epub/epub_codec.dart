import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:xml/xml.dart';

import '../../translation/translation_models.dart';
import '../ebook_codec.dart';
import 'xhtml_segmenter.dart';

final class EpubCodec implements EbookCodec {
  const EpubCodec({XhtmlSegmenter segmenter = const XhtmlSegmenter()})
    : _segmenter = segmenter;

  static const _manifestFileName = 'epub-workspace.json';
  static const _translationLogFileName = 'translations.jsonl';
  static const _contentDirectoryName = 'content';
  static const _sourceFileName = 'source.epub';

  final XhtmlSegmenter _segmenter;

  @override
  String get format => 'epub';

  @override
  bool supports(File source) =>
      path.extension(source.path).toLowerCase() == '.epub';

  @override
  Future<EbookSession> unpack(
    File source, {
    required Directory workspace,
  }) async {
    if (!await source.exists()) {
      throw EbookCodecException('The EPUB does not exist: ${source.path}');
    }
    if (!supports(source)) {
      throw const EbookCodecException('Only EPUB files are supported.');
    }

    await workspace.create(recursive: true);
    final contentDirectory = Directory(
      path.join(workspace.path, _contentDirectoryName),
    );
    await contentDirectory.create(recursive: true);
    await source.copy(path.join(workspace.path, _sourceFileName));

    final input = InputFileStream(source.path);
    late final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input, verify: true);
    } on Object catch (error) {
      input.closeSync();
      throw EbookCodecException('Unable to read the EPUB archive: $error');
    }

    final entries = <_EpubEntryRecord>[];
    try {
      for (var index = 0; index < archive.length; index++) {
        final entry = archive[index];
        if (entry.isSymbolicLink) {
          throw EbookCodecException(
            'Symbolic links are not allowed in EPUB files: ${entry.name}',
          );
        }
        final normalizedName = _safeEntryName(entry.name);
        final outputPath = _entryFilePath(contentDirectory, normalizedName);
        entries.add(
          _EpubEntryRecord(
            name: normalizedName,
            isFile: entry.isFile,
            compression: (entry.compression ?? CompressionType.deflate).name,
            mode: entry.mode,
            order: index,
          ),
        );

        if (entry.isDirectory) {
          await Directory(outputPath).create(recursive: true);
          continue;
        }
        await File(outputPath).parent.create(recursive: true);
        final output = OutputFileStream(outputPath);
        try {
          entry.writeContent(output);
        } finally {
          output.closeSync();
        }
      }
    } finally {
      archive.clearSync();
    }

    _validateMimetype(entries, contentDirectory);
    final publication = await _readPublication(contentDirectory);
    final manifest = _EpubWorkspaceManifest(
      sourcePath: source.absolute.path,
      title: publication.title,
      identifier: publication.identifier,
      opfPath: publication.opfPath,
      contentPaths: publication.contentPaths,
      entries: entries,
    );
    await _writeJsonAtomically(
      File(path.join(workspace.path, _manifestFileName)),
      manifest.toJson(),
    );

    return EpubSession._(
      workspace: workspace,
      manifest: manifest,
      segmenter: _segmenter,
    );
  }

  @override
  Future<EbookSession> restore(Directory workspace) async {
    final manifestFile = File(path.join(workspace.path, _manifestFileName));
    if (!await manifestFile.exists()) {
      throw EbookCodecException(
        'The EPUB workspace is incomplete: ${workspace.path}',
      );
    }
    final decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const EbookCodecException(
        'The EPUB workspace manifest is invalid.',
      );
    }
    return EpubSession._(
      workspace: workspace,
      manifest: _EpubWorkspaceManifest.fromJson(decoded),
      segmenter: _segmenter,
    );
  }

  static String _safeEntryName(String value) {
    final normalized = path.posix.normalize(value.replaceAll(r'\', '/'));
    if (normalized.isEmpty ||
        normalized == '.' ||
        normalized.startsWith('/') ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw EbookCodecException('Unsafe EPUB entry path: $value');
    }
    return normalized;
  }

  static String _entryFilePath(Directory root, String entryName) =>
      path.joinAll([root.path, ...path.posix.split(entryName)]);

  static void _validateMimetype(
    List<_EpubEntryRecord> entries,
    Directory contentDirectory,
  ) {
    final mimetype = entries.where((entry) => entry.name == 'mimetype');
    if (mimetype.length != 1) {
      throw const EbookCodecException(
        'The EPUB must contain exactly one mimetype entry.',
      );
    }
    final value = File(
      _entryFilePath(contentDirectory, 'mimetype'),
    ).readAsStringSync();
    if (value != 'application/epub+zip') {
      throw const EbookCodecException('The EPUB mimetype is invalid.');
    }
  }

  static Future<_Publication> _readPublication(
    Directory contentDirectory,
  ) async {
    final containerFile = File(
      _entryFilePath(contentDirectory, 'META-INF/container.xml'),
    );
    if (!await containerFile.exists()) {
      throw const EbookCodecException(
        'The EPUB is missing META-INF/container.xml.',
      );
    }

    final container = XmlDocument.parse(await containerFile.readAsString());
    final rootfile = _elementsNamed(container, 'rootfile').firstOrNull;
    final rawOpfPath = rootfile?.getAttribute('full-path');
    if (rawOpfPath == null || rawOpfPath.isEmpty) {
      throw const EbookCodecException(
        'The EPUB container does not identify an OPF package.',
      );
    }
    final opfPath = _safeEntryName(Uri.decodeComponent(rawOpfPath));
    final opfFile = File(_entryFilePath(contentDirectory, opfPath));
    if (!await opfFile.exists()) {
      throw EbookCodecException('The OPF package does not exist: $opfPath');
    }

    final package = XmlDocument.parse(await opfFile.readAsString());
    final packageElement = _elementsNamed(package, 'package').firstOrNull;
    final uniqueIdentifierId = packageElement?.getAttribute(
      'unique-identifier',
    );
    final identifiers = _elementsNamed(package, 'identifier');
    final identifier =
        identifiers
            .where(
              (element) =>
                  uniqueIdentifierId != null &&
                  element.getAttribute('id') == uniqueIdentifierId,
            )
            .firstOrNull
            ?.innerText
            .trim() ??
        identifiers.firstOrNull?.innerText.trim() ??
        '';
    final title =
        _elementsNamed(package, 'title').firstOrNull?.innerText.trim() ?? '';

    final manifestItems = <String, _ManifestItem>{};
    for (final item in _elementsNamed(package, 'item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      final mediaType = item.getAttribute('media-type');
      if (id == null || href == null || mediaType == null) {
        continue;
      }
      final uri = Uri.parse(href);
      final decodedPath = Uri.decodeComponent(uri.path);
      final resolvedPath = _safeEntryName(
        path.posix.normalize(
          path.posix.join(path.posix.dirname(opfPath), decodedPath),
        ),
      );
      manifestItems[id] = _ManifestItem(
        path: resolvedPath,
        mediaType: mediaType,
      );
    }

    final contentPaths = <String>[];
    for (final itemRef in _elementsNamed(package, 'itemref')) {
      final id = itemRef.getAttribute('idref');
      final item = id == null ? null : manifestItems[id];
      if (item?.mediaType == 'application/xhtml+xml' &&
          !contentPaths.contains(item!.path)) {
        contentPaths.add(item.path);
      }
    }
    for (final item in manifestItems.values) {
      if (item.mediaType == 'application/xhtml+xml' &&
          !contentPaths.contains(item.path)) {
        contentPaths.add(item.path);
      }
    }
    if (contentPaths.isEmpty) {
      throw const EbookCodecException(
        'The EPUB package contains no XHTML resources.',
      );
    }

    return _Publication(
      title: title,
      identifier: identifier,
      opfPath: opfPath,
      contentPaths: contentPaths,
    );
  }

  static Iterable<XmlElement> _elementsNamed(XmlNode node, String localName) =>
      node.descendants.whereType<XmlElement>().where(
        (element) => element.name.local == localName,
      );

  static Future<void> _writeJsonAtomically(
    File file,
    Map<String, Object?> value,
  ) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true,
    );
    await temporary.rename(file.path);
  }
}

final class EpubSession implements EbookSession {
  EpubSession._({
    required this.workspace,
    required _EpubWorkspaceManifest manifest,
    required XhtmlSegmenter segmenter,
  }) : _manifest = manifest,
       _segmenter = segmenter;

  @override
  final Directory workspace;
  final _EpubWorkspaceManifest _manifest;
  final XhtmlSegmenter _segmenter;

  Directory get _contentDirectory =>
      Directory(path.join(workspace.path, EpubCodec._contentDirectoryName));

  File get _translationLog =>
      File(path.join(workspace.path, EpubCodec._translationLogFileName));

  @override
  EbookPackageInfo get packageInfo => EbookPackageInfo(
    format: 'epub',
    title: _manifest.title,
    identifier: _manifest.identifier,
    sourcePath: _manifest.sourcePath,
    resourceCount: _manifest.entries.where((entry) => entry.isFile).length,
  );

  @override
  Stream<TranslationUnit> readTranslationUnits() async* {
    for (final resourcePath in _manifest.contentPaths) {
      final resource = File(
        EpubCodec._entryFilePath(_contentDirectory, resourcePath),
      );
      if (!await resource.exists()) {
        throw EbookCodecException(
          'The XHTML resource is missing: $resourcePath',
        );
      }
      final source = await resource.readAsString();
      for (final unit in _segmenter.segment(resourcePath, source)) {
        yield unit;
      }
    }
  }

  @override
  Future<Set<String>> recordedTranslationUnitIds() async {
    if (!await _translationLog.exists()) {
      return {};
    }
    final unitIds = <String>{};
    await for (final line
        in _translationLog
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic> || decoded['unit_id'] is! String) {
        throw const EbookCodecException(
          'The translation transcript is invalid.',
        );
      }
      unitIds.add(decoded['unit_id'] as String);
    }
    return unitIds;
  }

  @override
  Future<void> saveTranslation(
    TranslationUnit source,
    TranslatedUnit translation,
  ) async {
    if (source.id != translation.unitId) {
      throw const EbookCodecException(
        'The translated unit does not match its source unit.',
      );
    }
    final expectedIds = source.fragments.map((fragment) => fragment.id).toSet();
    if (expectedIds.length != translation.fragments.length ||
        expectedIds.difference(translation.fragments.keys.toSet()).isNotEmpty) {
      throw const EbookCodecException(
        'The translation does not contain all source fragments.',
      );
    }

    await _translationLog.parent.create(recursive: true);
    final record = {
      'unit_id': source.id,
      'resource_path': source.resourcePath,
      'source': {
        for (final fragment in source.fragments)
          fragment.id: fragment.sourceText,
      },
      'translation': translation.fragments,
    };
    await _translationLog.writeAsString(
      '${jsonEncode(record)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  @override
  Future<File> repack(File output) async {
    final translations = await _readTranslations();
    final patchedFiles = await _materializePatches(translations);
    await output.parent.create(recursive: true);

    final outputStream = OutputFileStream(output.path);
    final encoder = ZipEncoder()..startEncode(outputStream);
    try {
      final orderedEntries = [..._manifest.entries]
        ..sort((left, right) {
          if (left.name == 'mimetype') {
            return -1;
          }
          if (right.name == 'mimetype') {
            return 1;
          }
          return left.order.compareTo(right.order);
        });
      for (final record in orderedEntries) {
        if (!record.isFile) {
          final directory = ArchiveFile.directory(record.name)
            ..mode = record.mode;
          encoder.add(directory, autoClose: true);
          continue;
        }

        final sourceFile =
            patchedFiles[record.name] ??
            File(EpubCodec._entryFilePath(_contentDirectory, record.name));
        if (!await sourceFile.exists()) {
          throw EbookCodecException(
            'The unpacked EPUB entry is missing: ${record.name}',
          );
        }
        final input = InputFileStream(sourceFile.path);
        final archiveFile = ArchiveFile.stream(record.name, input)
          ..mode = record.mode
          ..compression = record.name == 'mimetype'
              ? CompressionType.none
              : CompressionType.values.byName(record.compression);
        encoder.add(archiveFile, autoClose: true);
      }
      encoder.endEncode();
    } finally {
      outputStream.closeSync();
    }
    return output;
  }

  Future<Map<String, _StoredTranslation>> _readTranslations() async {
    if (!await _translationLog.exists()) {
      return {};
    }
    final translations = <String, _StoredTranslation>{};
    await for (final line
        in _translationLog
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.trim().isEmpty) {
        continue;
      }
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic> ||
          decoded['unit_id'] is! String ||
          decoded['resource_path'] is! String ||
          decoded['translation'] is! Map<String, dynamic>) {
        throw const EbookCodecException(
          'The translation transcript is invalid.',
        );
      }
      translations[decoded['unit_id'] as String] = _StoredTranslation(
        unitId: decoded['unit_id'] as String,
        resourcePath: decoded['resource_path'] as String,
        fragments: (decoded['translation'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(key, value.toString()),
        ),
      );
    }
    return translations;
  }

  Future<Map<String, File>> _materializePatches(
    Map<String, _StoredTranslation> translations,
  ) async {
    if (translations.isEmpty) {
      return {};
    }
    final byResource = <String, List<_StoredTranslation>>{};
    for (final translation in translations.values) {
      byResource
          .putIfAbsent(translation.resourcePath, () => [])
          .add(translation);
    }

    final patchedRoot = Directory(path.join(workspace.path, 'patched'));
    final files = <String, File>{};
    for (final resourceEntry in byResource.entries) {
      final original = File(
        EpubCodec._entryFilePath(_contentDirectory, resourceEntry.key),
      );
      var source = await original.readAsString();
      final units = {
        for (final unit in _segmenter.segment(resourceEntry.key, source))
          unit.id: unit,
      };
      final replacements = <_TextReplacement>[];

      for (final translation in resourceEntry.value) {
        final unit = units[translation.unitId];
        if (unit == null) {
          throw EbookCodecException(
            'Translation unit ${translation.unitId} no longer matches '
            '${translation.resourcePath}.',
          );
        }
        for (final fragment in unit.fragments) {
          final translatedText = translation.fragments[fragment.id];
          if (translatedText == null) {
            throw EbookCodecException(
              'Translation unit ${translation.unitId} is missing '
              '${fragment.id}.',
            );
          }
          final encodedSource = source.substring(
            fragment.startOffset,
            fragment.endOffset,
          );
          final actualHash = sha256
              .convert(utf8.encode(encodedSource))
              .toString();
          if (actualHash != fragment.sourceHash) {
            throw EbookCodecException(
              'The source text changed before repacking '
              '${translation.resourcePath}.',
            );
          }
          replacements.add(
            _TextReplacement(
              start: fragment.startOffset,
              end: fragment.endOffset,
              value: encodeXmlText(translatedText),
            ),
          );
        }
      }

      replacements.sort((left, right) => right.start.compareTo(left.start));
      for (final replacement in replacements) {
        source = source.replaceRange(
          replacement.start,
          replacement.end,
          replacement.value,
        );
      }

      final patchedFile = File(
        EpubCodec._entryFilePath(patchedRoot, resourceEntry.key),
      );
      await patchedFile.parent.create(recursive: true);
      await patchedFile.writeAsString(source, flush: true);
      files[resourceEntry.key] = patchedFile;
    }
    return files;
  }
}

final class _EpubWorkspaceManifest {
  const _EpubWorkspaceManifest({
    required this.sourcePath,
    required this.title,
    required this.identifier,
    required this.opfPath,
    required this.contentPaths,
    required this.entries,
  });

  factory _EpubWorkspaceManifest.fromJson(Map<String, dynamic> json) {
    return _EpubWorkspaceManifest(
      sourcePath: json['source_path'] as String,
      title: json['title'] as String,
      identifier: json['identifier'] as String,
      opfPath: json['opf_path'] as String,
      contentPaths: (json['content_paths'] as List<dynamic>).cast<String>(),
      entries: (json['entries'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(_EpubEntryRecord.fromJson)
          .toList(growable: false),
    );
  }

  final String sourcePath;
  final String title;
  final String identifier;
  final String opfPath;
  final List<String> contentPaths;
  final List<_EpubEntryRecord> entries;

  Map<String, Object?> toJson() => {
    'version': 1,
    'source_path': sourcePath,
    'title': title,
    'identifier': identifier,
    'opf_path': opfPath,
    'content_paths': contentPaths,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };
}

final class _EpubEntryRecord {
  const _EpubEntryRecord({
    required this.name,
    required this.isFile,
    required this.compression,
    required this.mode,
    required this.order,
  });

  factory _EpubEntryRecord.fromJson(Map<String, dynamic> json) =>
      _EpubEntryRecord(
        name: json['name'] as String,
        isFile: json['is_file'] as bool,
        compression: json['compression'] as String,
        mode: json['mode'] as int,
        order: json['order'] as int,
      );

  final String name;
  final bool isFile;
  final String compression;
  final int mode;
  final int order;

  Map<String, Object> toJson() => {
    'name': name,
    'is_file': isFile,
    'compression': compression,
    'mode': mode,
    'order': order,
  };
}

final class _Publication {
  const _Publication({
    required this.title,
    required this.identifier,
    required this.opfPath,
    required this.contentPaths,
  });

  final String title;
  final String identifier;
  final String opfPath;
  final List<String> contentPaths;
}

final class _ManifestItem {
  const _ManifestItem({required this.path, required this.mediaType});

  final String path;
  final String mediaType;
}

final class _StoredTranslation {
  const _StoredTranslation({
    required this.unitId,
    required this.resourcePath,
    required this.fragments,
  });

  final String unitId;
  final String resourcePath;
  final Map<String, String> fragments;
}

final class _TextReplacement {
  const _TextReplacement({
    required this.start,
    required this.end,
    required this.value,
  });

  final int start;
  final int end;
  final String value;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
