// A VectorStore that keeps everything in a list in memory. Fine for a few
// thousand passages; start with this and swap in ObjectBox or sqlite-vec
// later without changing the rest of your code.
//
//   dart run example/memory_vector_store.dart
//
// Needs Ollama installed, plus:
//   ollama pull all-minilm

import 'dart:math' as math;

import 'package:rag_blocks/rag_blocks.dart';

class MemoryVectorStore implements VectorStore {
  MemoryVectorStore(this.embeddingModel);

  @override
  final String embeddingModel;

  final _stored = <StoredChunk>[];

  @override
  int get size => _stored.length;

  @override
  bool get isEmpty => _stored.isEmpty;

  @override
  void addAll(List<Chunk> chunks, List<List<double>> embeddings) {
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      _stored.add(
        StoredChunk(
          text: c.text,
          source: c.source,
          index: c.index,
          start: c.start,
          end: c.end,
          embedding: _normalise(embeddings[i]),
        ),
      );
    }
  }

  @override
  List<ScoredChunk> search(
    List<double> queryEmbedding, {
    int k = 5,
    int? maxPerSource,
    bool exact = false, // a list is always exact
  }) {
    final query = _normalise(queryEmbedding);
    final scored = [
      for (final c in _stored) ScoredChunk(c, _dot(query, c.embedding)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return capPerSource(scored, k, maxPerSource);
  }

  /// Scales [v] to length 1, so comparing two vectors is a plain dot product.
  static List<double> _normalise(List<double> v) {
    final length = math.sqrt(_dot(v, v));
    return [for (final x in v) x / length];
  }

  static double _dot(List<double> a, List<double> b) {
    var sum = 0.0;
    for (var i = 0; i < a.length; i++) {
      sum += a[i] * b[i];
    }
    return sum;
  }
}

Future<void> main() async {
  final ollama = await OllamaClient.connect(onStatus: print);
  final store = MemoryVectorStore('all-minilm');

  final passages = RecursiveCharacterTextSplitter(chunkSize: 200).splitText(
    'Customers may return unworn footwear within 21 days of purchase.\n\n'
    'The Heritage line carries an extended 45-day returns window.\n\n'
    'Full-time employees get 20 working days of paid annual leave.',
    source: 'handbook.md',
  );
  store.addAll(
    passages,
    await ollama.embed(
      model: store.embeddingModel,
      input: [for (final p in passages) p.text],
    ),
  );

  final hits = store.search(
    await ollama.embedOne(model: store.embeddingModel, input: 'returns window'),
    k: 2,
  );
  for (final hit in hits) {
    print('${hit.score.toStringAsFixed(2)}  ${hit.chunk.text}');
  }
  ollama.close();
}
