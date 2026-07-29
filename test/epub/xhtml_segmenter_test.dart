import 'package:flutter_test/flutter_test.dart';
import 'package:meow_translate/src/ebook/epub/xhtml_segmenter.dart';

void main() {
  const segmenter = XhtmlSegmenter();

  test('segments block content while preserving text locations', () {
    const source = '''
<html><head><title>Ignored</title></head><body>
<p id="a">Hello <em>brave</em> world &amp; friends.</p>
<script>doNotTranslate()</script>
</body></html>''';

    final units = segmenter.segment('chapter.xhtml', source);

    expect(units, hasLength(1));
    expect(units.single.kind, 'p');
    expect(units.single.fragments.map((fragment) => fragment.sourceText), [
      'Hello ',
      'brave',
      ' world & friends.',
    ]);
    for (final fragment in units.single.fragments) {
      expect(fragment.startOffset, lessThan(fragment.endOffset));
      expect(fragment.sourceHash, hasLength(64));
    }
  });

  test('stable IDs change when source content changes', () {
    final first = segmenter.segment('chapter.xhtml', '<p>Hello</p>').single;
    final same = segmenter.segment('chapter.xhtml', '<p>Hello</p>').single;
    final changed = segmenter.segment('chapter.xhtml', '<p>Hallo</p>').single;

    expect(first.id, same.id);
    expect(first.id, isNot(changed.id));
  });

  test('encodes translated text as XML text without touching quotes', () {
    expect(
      encodeXmlText('A & B < C > D "quoted"'),
      'A &amp; B &lt; C &gt; D "quoted"',
    );
  });

  test('decodes named XHTML entities into Unicode text', () {
    final unit = segmenter
        .segment('chapter.xhtml', '<p>One&nbsp;thing &copy; 2026</p>')
        .single;

    expect(unit.sourceText, 'One\u00a0thing © 2026');
    expect(encodeXmlText(unit.sourceText), isNot(contains('&amp;nbsp;')));
  });
}
