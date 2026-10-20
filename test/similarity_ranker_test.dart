import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:test/test.dart';

/// A stand-in embedding model that knows three topics, so rankings are
/// predictable: each text becomes [returns, leave, discount] word counts.
List<double> fakeEmbedding(String text) => [
  for (final topic in ['return', 'leave', 'discount'])
    topic.allMatches(text.toLowerCase()).length.toDouble() + 0.01,
];

/// An Ollama that answers /api/embed with [fakeEmbedding], and records the
/// model each request asked for.
OllamaClient fakeOllama(List<String> modelsAsked) => OllamaClient(
  client: MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    modelsAsked.add(body['model'] as String);
    final input = (body['input'] as List).cast<String>();
    return http.Response(
      jsonEncode({'embeddings': input.map(fakeEmbedding).toList()}),
      200,
    );
  }),
);

final chunks = [
  const Chunk(
    text: 'Shoes can be returned within 21 days.',
    source: 'policy.md',
    index: 0,
  ),
  const Chunk(
    text: 'Heritage returns: 45 days. Return the box too.',
    source: 'policy.md',
    index: 1,
  ),
  const Chunk(
    text: 'Staff get 20 days of annual leave.',
    source: 'handbook.md',
    index: 0,
  ),
  const Chunk(
    text: 'Staff get a 40% discount.',
    source: 'handbook.md',
    index: 1,
  ),
];

void main() {
  late List<String> modelsAsked;
  late SimilarityRanker ranker;

  setUp(() async {
    modelsAsked = [];
    ranker = SimilarityRanker(fakeOllama(modelsAsked).embedder('all-minilm'));
    await ranker.addAll(chunks);
  });

  test('ranks the closest chunks first', () async {
    final best = await ranker.rank('What is the returns window?', top: 2);
    expect(best.map((m) => m.chunk.source), ['policy.md', 'policy.md']);
    expect(best.first.score, greaterThanOrEqualTo(best.last.score));
  });

  test('top limits how many come back', () async {
    expect(await ranker.rank('returns', top: 1), hasLength(1));
    expect(await ranker.rank('returns'), hasLength(4));
  });

  test('maxPerSource lets other files in', () async {
    final best = await ranker.rank('returns', top: 2, maxPerSource: 1);
    expect(best.map((m) => m.chunk.source), ['policy.md', 'handbook.md']);
  });

  test('minScore drops weak matches', () async {
    final best = await ranker.rank('annual leave', minScore: 0.9);
    expect(best.single.chunk.text, contains('annual leave'));
  });

  test('chunks and questions use the same model', () async {
    await ranker.rank('returns');
    expect(modelsAsked.toSet(), {'all-minilm'});
  });

  test('nothing added means nothing found, without calling Ollama', () async {
    final empty = SimilarityRanker(fakeOllama(modelsAsked).embedder('m'));
    modelsAsked.clear();
    expect(await empty.rank('anything'), isEmpty);
    expect(modelsAsked, isEmpty);
  });

  test('chunks can be added in several goes, with progress', () async {
    final progress = <int>[];
    final r = SimilarityRanker(fakeOllama([]).embedder('m', batchSize: 1));
    await r.addAll(
      chunks.sublist(0, 2),
      onProgress: (done, _) => progress.add(done),
    );
    await r.addAll(chunks.sublist(2));
    expect(r.store.size, 4);
    expect(progress, [1, 2]);
  });

  test('a store filled by another model is rejected', () {
    expect(
      () => SimilarityRanker(
        fakeOllama([]).embedder('all-minilm'),
        store: InMemoryVectorStore('nomic-embed-text'),
      ),
      throwsArgumentError,
    );
  });

  test('works with an embedder that is not Ollama', () async {
    final r = SimilarityRanker(_OnDeviceEmbedder());
    await r.addAll(chunks);
    final best = await r.rank('annual leave', top: 1);
    expect(best.single.chunk.text, contains('annual leave'));
    expect(r.store.embeddingModel, 'on-device');
  });

  test('top must be positive', () {
    expect(() => ranker.rank('returns', top: 0), throwsArgumentError);
  });

  group('bestPieces', () {
    test('joins the ranked texts, best first, with blank lines', () async {
      final best = await ranker.rank('annual leave', top: 2);
      expect(best.bestPieces, '${best[0].chunk.text}\n\n${best[1].chunk.text}');
      expect(best.bestPieces, startsWith('Staff get 20 days of annual leave.'));
    });

    test('works straight on the result of rank', () async {
      final excerpts = (await ranker.rank('annual leave', top: 1)).bestPieces;
      expect(excerpts, 'Staff get 20 days of annual leave.');
    });

    test('is empty when nothing matched', () async {
      final none = await ranker.rank('annual leave', minScore: 2);
      expect(none.bestPieces, isEmpty);
    });
  });
}

/// An embedder written straight in Dart, as an on-device model would be.
class _OnDeviceEmbedder implements Embedder {
  @override
  String get model => 'on-device';

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    void Function(int done, int total)? onProgress,
  }) async => texts.map(fakeEmbedding).toList();
}
