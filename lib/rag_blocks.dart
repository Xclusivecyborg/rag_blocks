/// The building blocks of a RAG pipeline, separate from any one app.
///
/// Each piece does one job and knows nothing about the others, the way
/// LangChain's splitters, loaders and retrievers do. The app decides which
/// ones to use and in what order. See the README for a whole pipeline.
///
/// ```dart
/// final ollama = await OllamaClient.connect(); // starts `ollama serve` if needed
///
/// final splitter = RecursiveCharacterTextSplitter(
///   chunkSize: 600,
///   chunkOverlap: 200,
/// );
/// final chunks = splitter.splitText(text, source: 'handbook.md');
/// ```
library;

export 'src/document_loaders/directory_loader.dart';
export 'src/document_transformers/csv_to_prose.dart';
export 'src/llms/ollama_client.dart';
export 'src/llms/ollama_launcher.dart';
export 'src/query_transformers/query_condenser.dart';
export 'src/retrievers/cap_per_source.dart';
export 'src/retrievers/similarity_ranker.dart';
export 'src/tables/csv_table.dart';
export 'src/tables/table_query_planner.dart';
export 'src/text_splitters/recursive_character_text_splitter.dart';
export 'src/vector_stores/in_memory_vector_store.dart';
export 'src/vector_stores/vector_store.dart';
