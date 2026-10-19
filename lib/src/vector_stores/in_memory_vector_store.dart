import 'dart:math' as math;

import '../retrievers/cap_per_source.dart';
import '../text_splitters/recursive_character_text_splitter.dart';
import 'vector_store.dart';

/// How close in meaning two embeddings are, from -1 to 1. Near 1 means the
/// texts are about the same thing; near 0 means they are unrelated.
///
/// Throws [ArgumentError] if the lists differ in length, which happens when
/// they come from different embedding models.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.length != b.length) {
    throw ArgumentError(
      'Embeddings differ in length (${a.length} and ${b.length}). '
      'Were they made by different models?',
    );
  }
  final lengths = math.sqrt(_dot(a, a)) * math.sqrt(_dot(b, b));
  return lengths == 0 ? 0 : _dot(a, b) / lengths;
}

/// A [VectorStore] that keeps every chunk in a list in memory.
///
/// Search compares the query with every stored chunk, so it is always exact.
/// That is quick for a few thousand chunks. Past that, or to keep the index
/// between runs, implement [VectorStore] over a database instead.
class InMemoryVectorStore implements VectorStore {
  InMemoryVectorStore(this.embeddingModel);

  @override
  final String embeddingModel;

  final List<StoredChunk> _chunks = [];

  @override
  int get size => _chunks.length;

  @override
  bool get isEmpty => _chunks.isEmpty;

  /// Removes every stored chunk.
  void clear() => _chunks.clear();

  /// Throws [ArgumentError] unless there is one embedding per chunk.
  @override
  void addAll(List<Chunk> chunks, List<List<double>> embeddings) {
    if (chunks.length != embeddings.length) {
      throw ArgumentError(
        'Got ${chunks.length} chunks but ${embeddings.length} embeddings.',
      );
    }
    for (var i = 0; i < chunks.length; i++) {
      final c = chunks[i];
      _chunks.add(
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

  /// [exact] is ignored: every search here is exact.
  @override
  List<ScoredChunk> search(
    List<double> queryEmbedding, {
    int k = 5,
    int? maxPerSource,
    bool exact = false,
  }) {
    if (_chunks.isNotEmpty &&
        queryEmbedding.length != _chunks.first.embedding.length) {
      throw ArgumentError(
        'The query embedding has ${queryEmbedding.length} numbers but the '
        'stored ones have ${_chunks.first.embedding.length}. Embed the query '
        'with $embeddingModel.',
      );
    }
    final query = _normalise(queryEmbedding);
    final scored = [
      for (final c in _chunks) ScoredChunk(c, _dot(query, c.embedding)),
    ]..sort((a, b) => b.score.compareTo(a.score));
    return capPerSource(scored, k, maxPerSource);
  }
}

/// [v] scaled to length 1, so cosine similarity becomes a plain dot product.
List<double> _normalise(List<double> v) {
  final length = math.sqrt(_dot(v, v));
  return length == 0 ? List.of(v) : [for (final x in v) x / length];
}

double _dot(List<double> a, List<double> b) {
  var sum = 0.0;
  for (var i = 0; i < a.length; i++) {
    sum += a[i] * b[i];
  }
  return sum;
}
