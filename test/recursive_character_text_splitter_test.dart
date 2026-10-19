import 'package:test/test.dart';
import 'package:rag_blocks/rag_blocks.dart';

void main() {
  group('chunker', () {
    test('keeps short documents as a single chunk', () {
      final chunks = chunkDocument('One short paragraph.', source: 'a.md');
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'One short paragraph.');
      expect(chunks.single.source, 'a.md');
    });

    test('splits long documents into multiple chunks', () {
      final paragraph = '${'word ' * 60}\n\n';
      final chunks = chunkDocument(
        paragraph * 10,
        source: 'long.md',
        chunkSize: 500,
        chunkOverlap: 100,
      );
      expect(chunks.length, greaterThan(1));
    });

    test('overlaps consecutive chunks so boundary facts survive', () {
      final blocks = List.generate(
        30,
        (i) => 'Fact number $i about the business.',
      ).join('\n\n');
      final chunks = chunkDocument(
        blocks,
        source: 'facts.md',
        chunkSize: 300,
        chunkOverlap: 80,
      );
      expect(chunks.length, greaterThan(1));
      for (var i = 1; i < chunks.length; i++) {
        final firstWord = chunks[i].text.split(RegExp(r'\s+')).first;
        expect(
          chunks[i - 1].text,
          contains(firstWord),
          reason: 'chunk $i should begin with text carried from chunk ${i - 1}',
        );
      }
    });

    test('indexes chunks sequentially from zero', () {
      final chunks = chunkDocument(
        List.generate(20, (i) => 'Paragraph $i. ${'x' * 200}').join('\n\n'),
        source: 'doc.txt',
        chunkSize: 400,
      );
      expect(
        chunks.map((c) => c.index).toList(),
        List.generate(chunks.length, (i) => i),
      );
    });

    test('never emits empty or whitespace-only chunks', () {
      final chunks = chunkDocument(
        '\n\n\n   \n\nReal content here.\n\n\n   \n',
        source: 'messy.txt',
      );
      expect(chunks, isNotEmpty);
      expect(chunks.every((c) => c.text.trim().isNotEmpty), isTrue);
    });

    test('returns nothing for empty input', () {
      expect(chunkDocument('   \n\n  ', source: 'blank.txt'), isEmpty);
    });
  });

  group('the size ceiling', () {
    // This used to be a target rather than a ceiling. The overlap tail was
    // written into the buffer the moment a chunk was emitted, and the next
    // block went in with no size check, so a chunk could reach
    // chunkSize + chunkOverlap. Measured before the fix: 667 against a 600
    // target on the real corpus, and 802 on input with nothing to break on.
    void expectWithin(List<Chunk> chunks, int limit, String what) {
      for (final c in chunks) {
        expect(
          c.text.length,
          lessThanOrEqualTo(limit),
          reason: '$what: chunk ${c.index} is ${c.text.length} chars',
        );
      }
    }

    test('holds on ordinary prose', () {
      final doc = List.generate(
        40,
        (i) => 'Paragraph $i. ${'word ' * (10 + i % 40)}',
      ).join('\n\n');
      expectWithin(
        chunkDocument(doc, source: 'a.md', chunkSize: 600),
        600,
        'prose',
      );
    });

    test('holds when a paragraph has no blank line to break on', () {
      // The case CharacterTextSplitter gives up on and returns whole.
      final para =
          ('Stridewell Footwear Limited is a Nigerian footwear retailer. ' * 25)
              .trim();
      final chunks = chunkDocument(para, source: 'a.md', chunkSize: 600);
      expect(chunks.length, greaterThan(1), reason: 'must not give up whole');
      expectWithin(chunks, 600, 'single paragraph');
    });

    test('holds when there is nothing to break on at any level', () {
      // No blank lines, no sentence punctuation, no spaces. Only the hard cut
      // is left, and it used to emit 802 characters against a 600 target.
      final chunks = chunkDocument('x' * 1500, source: 'a.md', chunkSize: 600);
      expectWithin(chunks, 600, 'unbreakable run');
    });

    test('shrinks the overlap rather than breaching the ceiling', () {
      // Every block nearly fills a chunk on its own, so a full 200-character
      // tail cannot fit. The old code carried it anyway.
      final doc = List.generate(
        6,
        (i) => 'Block $i. ${'word ' * 115}',
      ).map((s) => s.trim()).join('\n\n');
      final chunks = chunkDocument(
        doc,
        source: 'a.md',
        chunkSize: 600,
        chunkOverlap: 200,
      );
      expectWithin(chunks, 600, 'tight blocks');
    });
  });

  group('source offsets', () {
    test('start points at the chunk\'s first real character', () {
      const doc = 'First paragraph here.\n\nSecond paragraph here.';
      final chunks = chunkDocument(
        doc,
        source: 'a.md',
        chunkSize: 25,
        chunkOverlap: 0,
      );
      expect(chunks.length, greaterThan(1));
      expect(doc.substring(chunks[0].start), startsWith('First paragraph'));
      expect(doc.substring(chunks[1].start), startsWith('Second paragraph'));
    });

    test('the span covers the chunk, whitespace aside', () {
      final doc = List.generate(
        30,
        (i) => 'Fact number $i about the business.',
      ).join('\n\n');
      final chunks = chunkDocument(
        doc,
        source: 'a.md',
        chunkSize: 300,
        chunkOverlap: 0,
      );
      for (final c in chunks) {
        // Exact span, but the text inside it is rejoined with a blank line,
        // so compare with whitespace collapsed rather than byte for byte.
        String flat(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();
        expect(
          flat(doc.substring(c.start, c.end)),
          flat(c.text),
          reason: 'chunk ${c.index}',
        );
      }
    });

    test('offsets are ascending and inside the document', () {
      final doc = List.generate(
        40,
        (i) => 'Paragraph $i. ${'word ' * 20}',
      ).join('\n\n');
      final chunks = chunkDocument(doc, source: 'a.md', chunkSize: 400);
      for (var i = 0; i < chunks.length; i++) {
        expect(chunks[i].start, lessThan(chunks[i].end));
        expect(chunks[i].end, lessThanOrEqualTo(doc.length));
        if (i > 0) {
          expect(chunks[i].start, greaterThan(chunks[i - 1].start));
        }
      }
    });

    test('offsets survive Windows line endings', () {
      // Normalising \r\n to \n shifts every later character left by one. An
      // offset measured on the cleaned-up copy drifts further from the truth
      // the deeper into the file you read, so it has to be mapped back.
      const unix =
          'First paragraph here.\n\nSecond paragraph here.\n\n'
          'Third paragraph here.';
      final windows = unix.replaceAll('\n', '\r\n');

      final chunks = chunkDocument(
        windows,
        source: 'a.md',
        chunkSize: 25,
        chunkOverlap: 0,
      );
      expect(chunks.length, 3);
      for (final c in chunks) {
        expect(
          windows.substring(c.start, c.end),
          c.text,
          reason: 'chunk ${c.index} must point at the bytes on disk',
        );
      }
    });

    test('offsets skip leading blank space in the file', () {
      const doc = '\n\n   \n\nReal content here.';
      final chunks = chunkDocument(doc, source: 'a.md');
      expect(
        doc.substring(chunks.single.start, chunks.single.end),
        'Real content here.',
      );
    });
  });

  group('arguments', () {
    test('a non-positive chunk size is rejected instead of looping', () {
      for (final size in [0, -1]) {
        expect(
          () => RecursiveCharacterTextSplitter(
            chunkSize: size,
            chunkOverlap: 0,
          ).splitText('text', source: 'x'),
          throwsArgumentError,
        );
      }
    });

    test('an overlap outside 0 to chunkSize is rejected', () {
      for (final overlap in [-1, 100, 150]) {
        expect(
          () => chunkDocument(
            'text',
            source: 'x',
            chunkSize: 100,
            chunkOverlap: overlap,
          ),
          throwsArgumentError,
        );
      }
    });
  });
}
