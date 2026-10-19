import 'package:rag_blocks/rag_blocks.dart';
import 'package:test/test.dart';

Chunk chunk(String text, {String source = 'a.md', int index = 0}) =>
    Chunk(text: text, source: source, index: index);

void main() {
  group('cosineSimilarity', () {
    test('is 1 for the same direction, whatever the length', () {
      expect(cosineSimilarity([1, 2], [2, 4]), closeTo(1, 1e-9));
    });

    test('is 0 for unrelated vectors and for an all-zero vector', () {
      expect(cosineSimilarity([1, 0], [0, 1]), 0);
      expect(cosineSimilarity([0, 0], [1, 1]), 0);
    });

    test('rejects vectors of different lengths', () {
      expect(() => cosineSimilarity([1, 0], [1, 0, 0]), throwsArgumentError);
    });
  });

  group('InMemoryVectorStore', () {
    late InMemoryVectorStore store;

    setUp(() {
      store = InMemoryVectorStore('model')
        ..addAll(
          [
            chunk('returns', source: 'policy.md'),
            chunk('leave', source: 'handbook.md'),
            chunk('returns again', source: 'policy.md', index: 1),
          ],
          [
            [1, 0],
            [0, 1],
            [0.9, 0.1],
          ],
        );
    });

    test('returns the closest chunks first, k at most', () {
      final hits = store.search([1, 0], k: 2);
      expect(hits.map((h) => h.chunk.text), ['returns', 'returns again']);
      expect(hits.first.score, closeTo(1, 1e-9));
    });

    test('scores do not depend on how long the vectors are', () {
      expect(store.search([10, 0], k: 1).single.score, closeTo(1, 1e-9));
    });

    test('maxPerSource lets other files in', () {
      final hits = store.search([1, 0], k: 2, maxPerSource: 1);
      expect(hits.map((h) => h.chunk.source), ['policy.md', 'handbook.md']);
    });

    test('keeps the chunk details', () {
      final stored = store.search([1, 0], k: 3).last.chunk;
      expect(stored.source, 'handbook.md');
      expect(stored.embedding, hasLength(2));
    });

    test('size, isEmpty and clear', () {
      expect(store.size, 3);
      store.clear();
      expect(store.isEmpty, isTrue);
      expect(store.search([1, 0]), isEmpty);
    });

    test('rejects a mismatched number of embeddings', () {
      expect(() => store.addAll([chunk('x')], const []), throwsArgumentError);
    });

    test('rejects a query from a different model', () {
      expect(() => store.search([1, 0, 0]), throwsArgumentError);
    });
  });
}
