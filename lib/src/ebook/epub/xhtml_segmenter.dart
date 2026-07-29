import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:html/parser.dart' as html_parser;

import '../../translation/translation_models.dart';

final class XhtmlSegmenter {
  const XhtmlSegmenter();

  static const _blockElements = {
    'address',
    'blockquote',
    'caption',
    'dd',
    'dt',
    'figcaption',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'li',
    'p',
    'td',
    'th',
  };

  static const _excludedElements = {'head', 'math', 'script', 'style', 'svg'};

  List<TranslationUnit> segment(String resourcePath, String source) =>
      segmentBlocks(
        resourcePath,
        source,
      ).map((block) => block.unit).toList(growable: false);

  List<XhtmlTranslationBlock> segmentBlocks(
    String resourcePath,
    String source,
  ) {
    final stack = <_OpenElement>[];
    final grouped = <String, _UnitBuilder>{};
    var cursor = 0;
    var fragmentOrdinal = 0;

    while (cursor < source.length) {
      final tagStart = source.indexOf('<', cursor);
      final textEnd = tagStart < 0 ? source.length : tagStart;
      if (textEnd > cursor && !_isExcluded(stack)) {
        final block = _nearestBlock(stack);
        if (block != null) {
          final encodedText = source.substring(cursor, textEnd);
          final decodedText = decodeXmlText(encodedText);
          if (decodedText.trim().isNotEmpty) {
            final key = '${block.name}@${block.startOffset}';
            final builder = grouped.putIfAbsent(
              key,
              () => _UnitBuilder(
                block: block,
                kind: block.name,
                firstOffset: cursor,
              ),
            );
            builder.fragments.add(
              TranslationFragment(
                id: 'f${fragmentOrdinal++}',
                sourceText: decodedText,
                sourceHash: sha256.convert(utf8.encode(encodedText)).toString(),
                startOffset: cursor,
                endOffset: textEnd,
              ),
            );
          }
        }
      }

      if (tagStart < 0) {
        break;
      }
      final tagEnd = _findTagEnd(source, tagStart);
      if (tagEnd < 0) {
        throw EbookMarkupException(
          'Unterminated markup in $resourcePath at offset $tagStart.',
        );
      }
      _updateStack(
        source.substring(tagStart, tagEnd + 1),
        tagStart,
        tagEnd + 1,
        stack,
      );
      cursor = tagEnd + 1;
    }

    final builders = grouped.values.toList()
      ..sort((a, b) => a.firstOffset.compareTo(b.firstOffset));
    return builders
        .map((builder) {
          final identity = [
            resourcePath,
            builder.kind,
            builder.firstOffset,
            ...builder.fragments.map((fragment) => fragment.sourceHash),
          ].join(':');
          return XhtmlTranslationBlock(
            unit: TranslationUnit(
              id: stableTranslationId(identity),
              resourcePath: resourcePath,
              kind: builder.kind,
              fragments: List.unmodifiable(builder.fragments),
            ),
            startOffset: builder.block.startOffset,
            endOffset: builder.block.endOffset ?? source.length,
          );
        })
        .toList(growable: false);
  }

  bool _isExcluded(List<_OpenElement> stack) =>
      stack.any((element) => _excludedElements.contains(element.name));

  _OpenElement? _nearestBlock(List<_OpenElement> stack) {
    for (final element in stack.reversed) {
      if (_blockElements.contains(element.name)) {
        return element;
      }
    }
    return null;
  }

  void _updateStack(
    String tag,
    int startOffset,
    int endOffset,
    List<_OpenElement> stack,
  ) {
    if (tag.startsWith('<!--') ||
        tag.startsWith('<!') ||
        tag.startsWith('<?')) {
      return;
    }

    final closing = RegExp(r'^<\s*/\s*([^\s>]+)').firstMatch(tag);
    if (closing != null) {
      final name = _localName(closing.group(1)!);
      for (var index = stack.length - 1; index >= 0; index--) {
        if (stack[index].name == name) {
          for (var removed = index; removed < stack.length; removed++) {
            stack[removed].endOffset ??= endOffset;
          }
          stack.removeRange(index, stack.length);
          return;
        }
      }
      return;
    }

    final opening = RegExp(r'^<\s*([^\s/>]+)').firstMatch(tag);
    if (opening == null || tag.trimRight().endsWith('/>')) {
      return;
    }
    stack.add(
      _OpenElement(
        name: _localName(opening.group(1)!),
        startOffset: startOffset,
      ),
    );
  }

  String _localName(String qualifiedName) =>
      qualifiedName.split(':').last.toLowerCase();
}

final class XhtmlTranslationBlock {
  const XhtmlTranslationBlock({
    required this.unit,
    required this.startOffset,
    required this.endOffset,
  });

  final TranslationUnit unit;
  final int startOffset;
  final int endOffset;
}

String decodeXmlText(String source) =>
    html_parser.parseFragment(source).text ?? '';

String encodeXmlText(String source) => source
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

String stripXmlIdentifiers(String source) {
  final output = StringBuffer();
  var cursor = 0;
  while (cursor < source.length) {
    final tagStart = source.indexOf('<', cursor);
    if (tagStart < 0) {
      output.write(source.substring(cursor));
      break;
    }
    output.write(source.substring(cursor, tagStart));
    final tagEnd = _findTagEnd(source, tagStart);
    if (tagEnd < 0) {
      output.write(source.substring(tagStart));
      break;
    }
    final tag = source.substring(tagStart, tagEnd + 1);
    if (tag.startsWith('</') || tag.startsWith('<!') || tag.startsWith('<?')) {
      output.write(tag);
    } else {
      output.write(_stripIdentifierAttributesFromTag(tag));
    }
    cursor = tagEnd + 1;
  }
  return output.toString();
}

String _stripIdentifierAttributesFromTag(String tag) {
  var cursor = 1;
  while (cursor < tag.length && _isXmlWhitespace(tag.codeUnitAt(cursor))) {
    cursor++;
  }
  while (cursor < tag.length &&
      !_isXmlWhitespace(tag.codeUnitAt(cursor)) &&
      tag[cursor] != '/' &&
      tag[cursor] != '>') {
    cursor++;
  }

  final removals = <_OffsetRange>[];
  while (cursor < tag.length) {
    final whitespaceStart = cursor;
    while (cursor < tag.length && _isXmlWhitespace(tag.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= tag.length || tag[cursor] == '/' || tag[cursor] == '>') {
      break;
    }

    final nameStart = cursor;
    while (cursor < tag.length &&
        !_isXmlWhitespace(tag.codeUnitAt(cursor)) &&
        tag[cursor] != '=' &&
        tag[cursor] != '/' &&
        tag[cursor] != '>') {
      cursor++;
    }
    final nameEnd = cursor;
    while (cursor < tag.length && _isXmlWhitespace(tag.codeUnitAt(cursor))) {
      cursor++;
    }

    var attributeEnd = nameEnd;
    if (cursor < tag.length && tag[cursor] == '=') {
      cursor++;
      while (cursor < tag.length && _isXmlWhitespace(tag.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor < tag.length && (tag[cursor] == '"' || tag[cursor] == "'")) {
        final quote = tag[cursor++];
        while (cursor < tag.length && tag[cursor] != quote) {
          cursor++;
        }
        if (cursor < tag.length) {
          cursor++;
        }
      } else {
        while (cursor < tag.length &&
            !_isXmlWhitespace(tag.codeUnitAt(cursor)) &&
            tag[cursor] != '>') {
          cursor++;
        }
      }
      attributeEnd = cursor;
    } else {
      cursor = nameEnd;
    }

    final name = tag.substring(nameStart, nameEnd).toLowerCase();
    if (name == 'id' || name == 'xml:id') {
      removals.add(_OffsetRange(start: whitespaceStart, end: attributeEnd));
    }
  }

  var result = tag;
  for (final removal in removals.reversed) {
    result = result.replaceRange(removal.start, removal.end, '');
  }
  return result;
}

bool _isXmlWhitespace(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0d;

int _findTagEnd(String source, int start) {
  if (source.startsWith('<!--', start)) {
    final end = source.indexOf('-->', start + 4);
    return end < 0 ? -1 : end + 2;
  }
  if (source.startsWith('<![CDATA[', start)) {
    final end = source.indexOf(']]>', start + 9);
    return end < 0 ? -1 : end + 2;
  }

  String? quote;
  for (var index = start + 1; index < source.length; index++) {
    final character = source[index];
    if (quote != null) {
      if (character == quote) {
        quote = null;
      }
    } else if (character == '"' || character == "'") {
      quote = character;
    } else if (character == '>') {
      return index;
    }
  }
  return -1;
}

final class EbookMarkupException implements Exception {
  const EbookMarkupException(this.message);

  final String message;

  @override
  String toString() => 'EbookMarkupException: $message';
}

final class _OpenElement {
  _OpenElement({required this.name, required this.startOffset});

  final String name;
  final int startOffset;
  int? endOffset;
}

final class _UnitBuilder {
  _UnitBuilder({
    required this.block,
    required this.kind,
    required this.firstOffset,
  });

  final _OpenElement block;
  final String kind;
  final int firstOffset;
  final List<TranslationFragment> fragments = [];
}

final class _OffsetRange {
  const _OffsetRange({required this.start, required this.end});

  final int start;
  final int end;
}
