/// Turns text into embeddings: lists of numbers that capture its meaning, so
/// texts about the same thing get similar numbers.
///
/// `SimilarityRanker` takes any [Embedder]. Use `ollama.embedder('all-minilm')`
/// for Ollama, or implement this to use another model, such as one that runs
/// on a phone:
///
/// ```dart
/// class OnDeviceEmbedder implements Embedder {
///   @override
///   String get model => 'all-minilm-onnx';
///
///   @override
///   Future<List<List<double>>> embed(
///     List<String> texts, {
///     void Function(int done, int total)? onProgress,
///   }) async => [for (final text in texts) await myModel.run(text)];
/// }
/// ```
abstract interface class Embedder {
  /// Names the model, so embeddings from different models are never mixed.
  /// A `VectorStore` filled by one embedder records this name.
  String get model;

  /// One embedding per text, in order. Every embedding from the same model
  /// has the same length.
  ///
  /// [onProgress] may be called with how many texts are done, for a progress
  /// bar.
  Future<List<List<double>>> embed(
    List<String> texts, {
    void Function(int done, int total)? onProgress,
  });
}
