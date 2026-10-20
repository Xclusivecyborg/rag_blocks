import '../text_splitters/recursive_character_text_splitter.dart';

/// A chunk as read back from a vector store.
class StoredChunk {
  StoredChunk({
    required this.text,
    required this.source,
    required this.index,
    required this.embedding,
    this.start = 0,
    this.end = 0,
  });

  final String text;
  final String source;
  final int index;

  /// Character range in [source]. Both are 0 on indexes built before this was
  /// saved, so treat `start == end` as "not recorded".
  final int start;
  final int end;

  /// Normalised to length 1, so cosine similarity is a plain dot product.
  final List<double> embedding;
}

class ScoredChunk {
  const ScoredChunk(this.chunk, this.score);
  final StoredChunk chunk;

  /// Cosine similarity, from -1 to 1. Higher is more similar.
  final double score;
}

/// Anything that stores embedded chunks and finds the nearest ones.
///
/// The package does not ship a database. The app plugs one in (ObjectBox,
/// sqlite-vec, or a list in memory), so this package stays free of native
/// libraries.
abstract interface class VectorStore {
  /// The model that produced the stored vectors. A query must be embedded by
  /// the same model, or its scores mean nothing.
  String get embeddingModel;

  int get size;
  bool get isEmpty;

  void addAll(List<Chunk> chunks, List<List<double>> embeddings);

  /// The [k] chunks closest to [queryEmbedding], best first, with at most
  /// [maxPerSource] from any one file when it is set.
  List<ScoredChunk> search(
    List<double> queryEmbedding, {
    int k = 5,
    int? maxPerSource,
  });
}
