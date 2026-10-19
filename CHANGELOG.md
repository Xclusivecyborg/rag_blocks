## 0.1.0

First release, extracted from the local_rag demo app.

- `RecursiveCharacterTextSplitter` with a hard chunk-size ceiling and
  character offsets for every chunk.
- `csvToProse`, which rewrites CSV rows as labelled sentences that embed well.
- `CsvTable` and `TableQueryPlanner`, for computing totals, averages, counts
  and breakdowns over every row instead of retrieving a few.
- `QueryCondenser`, which rewrites long questions and follow-ups into short
  search queries, and falls back to the original question on any failure.
- `OllamaClient` with `chat`, `chatStream`, `embed` and `connect`, and
  `OllamaLauncher` to start and stop `ollama serve` on macOS and Linux.
- `SimilarityRanker`, which finds the chunks closest in meaning to a
  question, with `top`, `maxPerSource` and `minScore` options.
- The `VectorStore` interface, a ready-made `InMemoryVectorStore`,
  `cosineSimilarity` and `capPerSource`.
- `findSupportedFiles` for loading a folder of documents.
