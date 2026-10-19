# rag_blocks

Let an AI answer questions about **your own documents**, in pure Dart,
entirely on your own computer. No cloud account, no API key, and your files
never leave the machine. The AI runs through [Ollama](https://ollama.com), a
free app for running AI models locally.

## How it works

A chat AI has never seen your documents, so if you ask it about your returns
policy it will guess. The fix, known as **RAG**, works like an open-book exam:

1. **Look it up:** find the few passages in your files that relate to the
   question.
2. **Hand them over:** include those passages in the message to the AI.
3. **Answer from them:** tell the AI to answer using only those passages.

This package gives you each step as a separate building block, like
[LangChain](https://www.langchain.com) does in Python. Use only the ones you
need.

## Setup

1. Install Ollama from [ollama.com](https://ollama.com) (or `brew install
   ollama` on a Mac).
2. Download two AI models: a small one that powers the search, and one that
   writes the answers.

   ```bash
   ollama pull all-minilm
   ollama pull llama3.2
   ```

3. Add the package to your Dart or Flutter project:

   ```bash
   dart pub add rag_blocks
   ```

## Quick start

Let's give the AI a short shop handbook and ask it a question it could only
answer by reading it. The program does four things.

**Step 1: Connect to Ollama.**

```dart
final ollama = await OllamaClient.connect(onStatus: print);
```

This finds Ollama on your computer and starts it if it isn't running.
`onStatus: print` prints what it's doing, such as "Starting ollama serve…".

**Step 2: Cut the handbook into small pieces.**

```dart
final splitter = RecursiveCharacterTextSplitter(chunkSize: 200, chunkOverlap: 40);
final pieces = splitter.splitText(handbook, source: 'handbook.md');
```

Searching works best on small pieces, because each piece is about one thing.
`chunkSize: 200` means no piece is longer than 200 characters.
`chunkOverlap: 40` repeats the last bit of each piece at the start of the
next, so a sentence that falls on the cut isn't lost.

**Step 3: Find the pieces that best match the question.**

```dart
final ranker = SimilarityRanker(ollama, model: 'all-minilm');
await ranker.addAll(pieces);

const question = 'How long do I have to return Heritage shoes?';
final best = await ranker.rank(question, top: 2);
final bestPieces = best.map((match) => match.chunk.text).join('\n\n');
```

The ranker is the search. When you add pieces, it uses the `all-minilm`
model to describe the *meaning* of each one, so pieces about the same topic
are recognised as similar even when they use different words. `rank` then
compares the question with every piece and returns the closest ones, best
first. `top: 2` asks for the best two.

You can also limit how many pieces come from one file (`maxPerSource`) and
leave out loosely related ones (`minScore`). The
[guide](doc/guide.md#finding-the-best-passages-similarityranker) explains
both.

**Step 4: Ask the chat model, giving it only those pieces.**

```dart
final reply = await ollama.chat(
  model: 'llama3.2',
  messages: [
    const ChatMessage('system', 'Answer using only the excerpts. If they do not say, reply "I don\'t know."'),
    ChatMessage('user', 'Excerpts:\n$bestPieces\n\nQuestion: $question'),
  ],
);
print(reply.content); // Heritage shoes can be returned within 45 days.
```

The `system` message sets the rules, and the `user` message carries the
pieces and the question. Because the AI is told to stick to the pieces, it
answers from your handbook instead of guessing, and says "I don't know"
when the handbook doesn't cover the question.

The whole program is in [`example/main.dart`](example/main.dart). Run it
with `dart run example/main.dart`.

## The blocks

| Block | What it does |
|---|---|
| [`findSupportedFiles`](#load-a-folder) | Lists the documents in a folder. |
| [`RecursiveCharacterTextSplitter`](#cut-text-into-pieces) | Cuts documents into small pieces for searching. |
| [`csvToProse`](#make-spreadsheets-searchable) | Turns spreadsheet rows into sentences the search understands. |
| [`CsvTable`, `TableQueryPlanner`](#get-exact-totals-from-spreadsheets) | Works out totals and averages over every row, instead of letting the AI guess. |
| [`QueryCondenser`](#improve-questions-before-searching) | Shortens long questions and completes follow-ups before searching. |
| [`OllamaClient`, `OllamaLauncher`](#talk-to-ollama) | Talks to Ollama, and starts or stops it. |
| [`SimilarityRanker`](#find-the-best-pieces) | Finds the pieces closest in meaning to a question. |
| [`VectorStore`, `InMemoryVectorStore`](#keep-pieces-in-a-database) | Where the ranker keeps pieces: in memory, or in your own database. |

### Load a folder

Lists every `.txt`, `.md`, `.csv`, `.json` and `.log` file in a folder and
its subfolders, skipping hidden ones like `.git`.

```dart
final files = await findSupportedFiles(Directory('knowledge_base'));
```

### Cut text into pieces

Cuts between paragraphs first, then between sentences, and never makes a
piece longer than `chunkSize`. Each piece remembers where it came from, so
you can show the source of an answer.

```dart
final pieces = RecursiveCharacterTextSplitter().splitText(text, source: 'policies.md');
final first = pieces.first;
print('${first.source}, characters ${first.start}–${first.end}: ${first.text}');
```

### Make spreadsheets searchable

A row like `SHO-114,Lagos,12` means little on its own. `csvToProse` adds the
column names, so a question about "staff in Lagos" can find it.

```dart
print(csvToProse('branch,city,staff\nSHO-114,Lagos,12'));
// Record 1. branch: SHO-114. city: Lagos. staff: 12.
```

### Get exact totals from spreadsheets

The search only shows the AI a few rows, so if you ask for a total it adds
up those few and gets it wrong. `TableQueryPlanner` spots questions about
totals, averages, counts, highest and lowest, and works them out over every
row:

```dart
final sales = CsvTable.parse(csvText, source: 'sales.csv');
final result = TableQueryPlanner.answer([sales], 'What was total revenue in January 2026?');
print(result?.toPromptBlock());
// Total revenue_ngn in January 2026: 71,882,000
// Computed over 80 matching row(s) out of 240 in sales.csv.
```

Include that text in your message to the AI, and it will quote the exact
figure. When the question isn't clearly a calculation, `answer` returns
`null` and you use the normal search instead.

### Improve questions before searching

Long questions full of extra detail search badly, and follow-ups like "and
the Abuja one?" mean nothing on their own. `QueryCondenser` asks the chat
model to rewrite the question into a few search words. If anything goes
wrong, you get the original question back.

```dart
final condensed = await QueryCondenser(ollama).condense(
  model: 'llama3.2',
  question: 'and the Abuja one?',
  history: ['Where is the Lagos branch?'],
);
print(condensed.text); // Abuja branch location
```

### Talk to Ollama

`OllamaClient` does the talking: `chat` gets a whole reply, `chatStream`
gets a reply word by word as it's written, `listModels` shows what's
installed, and `embed` describes text as numbers for searching (the ranker
uses it for you).

```dart
await for (final piece in ollama.chatStream(model: 'llama3.2', messages: messages)) {
  stdout.write(piece.content ?? '');
}
```

`OllamaLauncher` starts and stops Ollama, for when you want your own
"Start" and "Stop" buttons. `OllamaClient.connect()` already uses it.

### Find the best pieces

Give the ranker your pieces once, then ask it for the best matches to each
question, as in the quick start. Optional settings:

```dart
final best = await ranker.rank(
  question,
  top: 5,          // at most 5 pieces
  maxPerSource: 2, // at most 2 from any one file
  minScore: 0.3,   // skip pieces that are only loosely related
);
```

### Keep pieces in a database

The ranker keeps pieces in memory by default, so they're gone when your app
closes. To keep them, write a small class that implements `VectorStore`
over a database such as ObjectBox or sqlite-vec, and pass it to the ranker
with `store:`. See the
[guide](doc/guide.md#keeping-passages-in-a-database-vectorstore).

## Learn more

The [guide](doc/guide.md) covers every option, how to combine the blocks
into one `answer()` function, how to choose sizes and models, and what to
do when answers go wrong.

## Where it runs

Command-line tools, servers and Flutter apps on macOS, Linux and Windows.
On Windows, start Ollama yourself for now; everything else works the same.
Web apps aren't supported yet.

## Running the tests

```bash
dart test
```

The tests don't need Ollama installed.

## Contributing

Bug reports and pull requests are welcome on
[GitHub](https://github.com/Xclusivecyborg/rag_blocks/issues).

## License

MIT. See [LICENSE](LICENSE).
