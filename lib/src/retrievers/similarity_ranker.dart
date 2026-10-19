import '../llms/ollama_client.dart';
import '../text_splitters/recursive_character_text_splitter.dart';
import '../vector_stores/in_memory_vector_store.dart';
import '../vector_stores/vector_store.dart';

/// Finds the chunks whose meaning is closest to a question.
///
/// Add your chunks once with [addAll], then call [rank] for each question.
/// It embeds the chunks and the question with [model] and compares them, so
/// you don't have to handle the embeddings yourself.
///
/// ```dart
/// final ranker = SimilarityRanker(ollama, model: 'all-minilm');
/// await ranker.addAll(chunks);
/// final best = await ranker.rank('How long is the returns window?', top: 3);
/// for (final match in best) {
///   print('${match.score.toStringAsFixed(2)} ${match.chunk.text}');
/// }
/// ```
///
/// Chunks are kept in an [InMemoryVectorStore] unless you pass a [store] of
/// your own, such as one backed by a database.
class SimilarityRanker {
  /// Throws [ArgumentError] if [store] was filled by a model other than
  /// [model], because their embeddings cannot be compared.
  SimilarityRanker(
    this._ollama, {
    required this.model,
    VectorStore? store,
    this.batchSize = 16,
  }) : store = store ?? InMemoryVectorStore(model) {
    if (this.store.embeddingModel != model) {
      throw ArgumentError(
        'The store holds embeddings from ${this.store.embeddingModel}, '
        'but this ranker uses $model.',
      );
    }
  }

  final OllamaClient _ollama;

  /// The embedding model used for chunks and questions alike.
  final String model;

  /// Where the embedded chunks are kept.
  final VectorStore store;

  /// How many chunks to embed per request to Ollama.
  final int batchSize;

  /// Embeds [chunks] and adds them to [store]. Call it again to add more.
  ///
  /// [onProgress] reports how many chunks are done, for a progress bar.
  Future<void> addAll(
    List<Chunk> chunks, {
    void Function(int done, int total)? onProgress,
  }) async {
    if (chunks.isEmpty) return;
    final embeddings = await _ollama.embed(
      model: model,
      input: [for (final c in chunks) c.text],
      batchSize: batchSize,
      onProgress: onProgress,
    );
    store.addAll(chunks, embeddings);
  }

  /// The chunks closest in meaning to [question], best first.
  ///
  /// - [top]: the most chunks to return.
  /// - [maxPerSource]: the most to take from any one file, so a large file
  ///   cannot fill every slot. No limit when null.
  /// - [minScore]: drop chunks scoring below this, from 0 (unrelated) to 1
  ///   (same meaning). Returning nothing then means nothing was relevant,
  ///   which is a good moment to answer "I don't know". The right value
  ///   depends on the model; with `all-minilm`, around 0.3 is a fair start.
  ///
  /// Returns an empty list when nothing has been added. Use
  /// [RankedChunks.bestPieces] on the result to get the text alone, ready to
  /// paste into a prompt.
  Future<List<ScoredChunk>> rank(
    String question, {
    int top = 5,
    int? maxPerSource,
    double? minScore,
  }) async {
    if (top <= 0) {
      throw ArgumentError.value(top, 'top', 'must be positive');
    }
    if (store.isEmpty) return const [];
    final query = await _ollama.embedOne(model: model, input: question);
    final hits = store.search(query, k: top, maxPerSource: maxPerSource);
    return [
      for (final hit in hits)
        if (minScore == null || hit.score >= minScore) hit,
    ];
  }
}

/// Shortcuts on the list that [SimilarityRanker.rank] returns.
extension RankedChunks on List<ScoredChunk> {
  /// The text of every chunk, best first, separated by blank lines. Ready to
  /// paste into a prompt as the excerpts to answer from. Empty when the list
  /// is empty.
  ///
  /// ```dart
  /// final excerpts = (await ranker.rank(question, top: 2)).bestPieces;
  /// ```
  String get bestPieces => map((match) => match.chunk.text).join('\n\n');
}
