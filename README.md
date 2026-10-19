# rag_blocks

The building blocks of a local RAG pipeline, in pure Dart. You get a text
splitter, CSV-to-prose, exact table arithmetic, a query condenser and an
Ollama client. Each one does a single job, the way LangChain's splitters and
retrievers do, and you choose which ones to snap together.

The only dependency is `package:http`. There's no Flutter, no Python and no
server beyond Ollama itself, so it runs in a command-line tool, a Flutter app
or a backend.

## Install

```bash
dart pub add rag_blocks
```

You also need [Ollama](https://ollama.com) with an embedding model and a chat
model:

```bash
ollama pull all-minilm
ollama pull llama3.2
```

## A whole pipeline

```dart
import 'package:rag_blocks/rag_blocks.dart';

final ollama = await OllamaClient.connect(); // starts `ollama serve` if needed

final splitter = RecursiveCharacterTextSplitter(chunkSize: 600, chunkOverlap: 200);
final chunks = splitter.splitText(handbookText, source: 'handbook.md');

final vectors = await ollama.embed(
  model: 'all-minilm',
  input: [for (final c in chunks) c.text],
);
// ...store the vectors, then embed the question and find the closest chunks...

final reply = await ollama.chat(
  model: 'llama3.2',
  messages: [
    const ChatMessage('system', 'Answer using only the excerpts.'),
    ChatMessage('user', 'Excerpts:\n$context\n\nQuestion: $question'),
  ],
);
print(reply.content);
```

[`example/main.dart`](example/main.dart) runs this end to end, with a
plain list standing in for the vector database.

## The blocks

### Splitting

`RecursiveCharacterTextSplitter` breaks text at paragraphs first, then at
sentences, then at words. It never makes a chunk longer than `chunkSize`, and
each chunk records the character range it came from, so you can show a
citation.

### CSV that embeds well

A raw CSV line like `SHO-114,Lagos,2026-03-02,48` gives an embedding model
almost nothing to match. `csvToProse` rewrites each row as labelled sentences
instead, such as `location: Lagos. units_sold: 48.`

### Exact arithmetic over tables

Retrieval only ever shows the model a handful of rows, so a model asked to
"total January's revenue" adds up five rows and guesses. `TableQueryPlanner`
recognises questions about totals, averages, counts, highest and lowest, and
works them out over every row:

```dart
final sales = CsvTable.parse(csvText, source: 'sales.csv');
final result = TableQueryPlanner.answer([sales], 'What was total revenue in January?');
if (result != null) {
  print(result.toPromptBlock()); // the figure, and how many rows it covers
}
```

It returns null for anything that isn't clearly a calculation, so the caller
can fall back to retrieval. A question like "how much annual leave do staff
get?" never comes back as the sum of a sales column.

### Rewriting questions before searching

An embedding represents the whole sentence, so a long question with extra
clauses drifts away from the document it needs. `QueryCondenser` asks the chat
model to boil the question down to a short search query. It also turns a
follow-up like "and the Abuja one?" into a complete query using the
conversation so far. If anything goes wrong, you get the original question
back.

```dart
final condensed = await QueryCondenser(ollama).condense(
  model: 'llama3.2',
  question: question,
  history: previousQuestions,
);
final queryVector = await ollama.embedOne(model: 'all-minilm', input: condensed.text);
```

### Ollama

`OllamaClient` covers what a RAG pipeline needs: `embed`, `embedOne`, `chat`
for the whole reply, `chatStream` for a reply as it is written, `listModels`
and `version`. `OllamaClient.connect()` starts `ollama serve` for you when
nothing is answering and the base URL is on this machine, and throws an `OllamaException` that says why if Ollama
isn't installed or won't start. `OllamaLauncher` exposes the start and stop
steps on their own.

Starting and stopping Ollama works on macOS, Linux and Windows. A sandboxed
macOS app can't start processes, so turn off `com.apple.security.app-sandbox`
if you want the app to launch Ollama.

### Vector stores

The package doesn't include a database. `VectorStore` is the interface your
store implements, whether it's ObjectBox, sqlite-vec or a list in memory.
`capPerSource` stops one large file from filling every result slot.

### Loading a folder

`findSupportedFiles` lists every `.txt`, `.md`, `.csv`, `.json` and `.log`
file in a folder, skipping hidden files.

## Running the tests

```bash
dart test
```
