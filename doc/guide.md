# rag_blocks guide

The [README](../README.md) shows each block in a few lines. This guide covers
the details: every option, how the pieces fit together, how to choose
settings, and what to do when answers go wrong.

- [The blocks in detail](#the-blocks-in-detail)
- [Putting it all together](#putting-it-all-together)
- [Choosing settings](#choosing-settings)
- [Where it runs](#where-it-runs)
- [Troubleshooting](#troubleshooting)
- [What it doesn't do (yet)](#what-it-doesnt-do-yet)
- [Words used in this guide](#words-used-in-this-guide)

## The blocks in detail

### Loading a folder: `findSupportedFiles`

It lists every document in a folder and its subfolders that the other blocks
can read: `.txt`, `.md`, `.markdown`, `.csv`, `.json` and `.log`. Hidden
files and hidden folders (like `.git`) are skipped, and the list comes back
in alphabetical order.

```dart
import 'dart:io';

import 'package:rag_blocks/rag_blocks.dart';

Future<void> main() async {
  final files = await findSupportedFiles(Directory('knowledge_base'));

  for (final file in files) {
    final text = await file.readAsString();
    final isSpreadsheet = fileExtension(file.path) == '.csv';
    print('${file.path}: ${text.length} characters, spreadsheet: $isSpreadsheet');
  }
}
```

It only finds the files. Reading them is up to you, which means you can
also add your own types, for example by converting PDFs to text first.

### Cutting documents into passages: `RecursiveCharacterTextSplitter`

**Why:** a search compares the question with each passage as a whole. A
20-page document is about many things at once, so it matches every question
a little and none of them well. Short passages are each about one thing, so
the right one stands out.

**How it cuts:** it tries to break between paragraphs first, then between
sentences, and only cuts mid-sentence when a sentence is longer than the
limit. No passage is ever longer than `chunkSize` characters.

**Overlap:** the end of each passage is repeated at the start of the next,
so a fact that sits right on a cut still appears whole in one of them.

```dart
const policies = '''
Customers may return unworn footwear within 21 days of purchase for a full refund. Items must be in their original box.

The Heritage line carries an extended 45-day returns window. Sale items can be exchanged but not refunded.

Full-time employees accrue 20 working days of paid annual leave per year.''';

final splitter = RecursiveCharacterTextSplitter(chunkSize: 160, chunkOverlap: 40);
final passages = splitter.splitText(policies, source: 'policies.md');

for (final p in passages) {
  print('#${p.index} (characters ${p.start}–${p.end} of ${p.source})');
  print(p.text);
}
```

Output, shortened:

```text
#0 (characters 0–119 of policies.md)
Customers may return unworn footwear within 21 days of purchase for a full refund. Items must be in their original box.
#1 (characters 121–227 of policies.md)
Items must be in their original box.

The Heritage line carries an extended 45-day returns window. Sale items can be exchanged but not refunded.
#2 (characters 229–302 of policies.md)
...
```

Passage #1 starts with the last sentence of #0. That's the overlap.

**Showing where an answer came from:** every passage remembers where it sits
in the original file (`start` and `end`), so you can show a "source" link or
highlight the passage:

```dart
final p = passages.first;
final original = policies.substring(p.start, p.end);
print('From ${p.source}: "$original"');
```

For a single document you can call the function form instead:
`chunkDocument(text, source: 'notes.md', chunkSize: 400)`.

### Spreadsheets the search can understand: `csvToProse`

A spreadsheet row like `SHO-114,Lagos,2021-03-02,12` means nothing out of
context. The search can't tell that `Lagos` is a city or that `12` is a
number of staff. `csvToProse` writes each row out as a sentence with its
column names:

```dart
const branches = '''
branch,city,opened,staff
SHO-114,Lagos,2021-03-02,12
SHO-201,Abuja,2023-07-15,8''';

print(csvToProse(branches));
```

```text
Record 1. branch: SHO-114. city: Lagos. opened: 2021-03-02. staff: 12.

Record 2. branch: SHO-201. city: Abuja. opened: 2023-07-15. staff: 8.
```

Now "How many staff are at the Lagos branch?" finds record 1. Pass the result
to the splitter like any other text. Each record is its own paragraph, so
records are never cut in half.

Quoted values that contain commas or line breaks (`"Doe, Jane"`) are handled.

### Exact maths over spreadsheets: `CsvTable` and `TableQueryPlanner`

**The problem:** the search only hands the AI a few passages. Ask "what was
our total revenue in January?" and the AI sees 5 of the 80 January rows,
adds them up, and gives a confident wrong number.

**The fix:** keep the spreadsheet as a table too. When a question is clearly
a calculation, do the maths in code over every row and give the AI the exact
figure.

```dart
final sales = CsvTable.parse(
  File('sales_q1_2026.csv').readAsStringSync(),
  source: 'sales_q1_2026.csv',
);

final result = TableQueryPlanner.answer(
  [sales],
  'What was total revenue in January 2026?',
);

if (result != null) {
  print(result.toPromptBlock());
}
```

```text
Total revenue_ngn in January 2026: 71,882,000
Computed over 80 matching row(s) out of 240 in sales_q1_2026.csv.
```

Paste that block into the message to the AI, and it will quote the figure
instead of guessing. The second line matters: it tells the AI that the
figure covers everything, so it doesn't hedge.

**Questions it understands:**

| You ask | It works out |
|---|---|
| "Total revenue in January 2026" | the sum of a column, for one month |
| "Average units sold by location in Q1 2026" | the average, plus one average per location |
| "Which location had the highest revenue in March 2026?" | the largest value **and the row it came from** |
| "Lowest units returned in 2026" | the smallest value and its row |
| "Total revenue for the Heritage line in February 2026" | a sum over only the Heritage rows |
| "How many records for Online?" | a count of rows |

For example, "Average units sold by location in Q1 2026" gives:

```text
Average units_sold in Q1 2026: 18.21
Computed over 240 matching row(s) out of 240 in sales_q1_2026.csv.
Breakdown:
  Ikeja City Mall: 20.15
  Online: 18.63
  Port Harcourt: 8.29
  Victoria Island: 28.29
  Wuse 2 Abuja: 15.69
```

And "Which location had the highest revenue in March 2026?" adds the row
that answers "which":

```text
Maximum revenue_ngn in March 2026: 2,997,000
Computed over 80 matching row(s) out of 240 in sales_q1_2026.csv.
Found in the row: week_starting=2026-03-09, location=Victoria Island, ...
```

You can read the same details in code: `result.value`, `result.groups` and
`result.extremeRow`.

**How it reads a question:**

- **Which column:** it matches words in the question against column names.
  "revenue" finds `revenue_ngn`, and a few everyday words are understood
  too ("sales" and "income" mean revenue).
- **Which rows:** any value from the spreadsheet that appears in the
  question becomes a filter, such as "Heritage" or "Online".
- **Which dates:** "January 2026", "Q1 2026" or "2026". A **year is
  required**, so "January" alone never quietly mixes several years.
- **Which breakdown:** "by location" or "per product line" splits the result.

**It says "not me" when it isn't sure.** `answer` returns `null` when the
question isn't clearly a calculation, or when two columns match equally
well. That's on purpose: "How much annual leave do staff get?" contains "how
much" but must not come back as the sum of a sales column. When you get
`null`, use the normal search instead.

You can also skip the question reading and ask directly:

```dart
final heritageFebruary = sales.aggregate(
  TableQuery(
    aggregate: Aggregate.sum,
    metric: 'revenue_ngn',
    filters: const [ColumnFilter('product_line', 'Heritage')],
    range: DateRange(DateTime(2026, 2), DateTime(2026, 3), 'February 2026'),
  ),
);
print(heritageFebruary?.value); // 8924000
```

**Saving tables between runs:** reading a large CSV every time is wasteful,
so save the tables next to your search index:

```dart
File('tables.json').writeAsStringSync(CsvTable.encodeAll([sales]));

// Later, or on the next launch:
final tables = CsvTable.decodeAll(File('tables.json').readAsStringSync());
```

`decodeAll` returns an empty list instead of crashing if the file is damaged.
If that happens, just read the CSVs again.

### Better questions, better searches: `QueryCondenser`

**The problem:** the search compares meaning, and everything in the question
counts. "How much discount will I get if I buy shoes worth 100,000 naira as
an employee?" is mostly about shoes and money, so the staff handbook,
which talks about the *employee discount*, ranks far down the list.

Follow-ups are worse. "And the Abuja one?" means nothing by itself.

**The fix:** before searching, ask the chat model to boil the question down
to a few search words, using the conversation so far:

```dart
final condenser = QueryCondenser(ollama);

final first = await condenser.condense(
  model: 'llama3.2',
  question: 'How much discount will I get if I buy shoes worth 100,000 naira '
      'as an employee?',
);
print(first.text); // employee discount policy

final followUp = await condenser.condense(
  model: 'llama3.2',
  question: 'and the Abuja one?',
  history: ['Where is the Lagos branch?'],
);
print(followUp.text); // Abuja branch location

// Search with the short version...
final searchFingerprint = await ollama.embedOne(
  model: 'all-minilm',
  input: followUp.text,
);
// ...but send the user's original words to the chat model.
```

**It never makes things worse.** If the model is slow, unreachable, refuses,
or replies with something that doesn't look like a search query, you get
the original question back. It never throws. You can see what happened:

```dart
if (!first.wasCondensed) {
  print('Kept the original question: ${first.note}');
  // e.g. "short question, left alone" or "condense failed: ..."
}
```

Short questions (under 8 words) with no conversation history are left
alone, because they are already good search queries. That also saves a call
to the model.

Settings: `QueryCondenser(ollama, timeout: Duration(seconds: 10))` controls
how long to wait. If you use a "thinking" model (one that reasons before it
answers), pass `thinkingModel: true` to skip the reasoning; a rewrite this
small doesn't need it.

### Talking to the AI: `OllamaClient`

**Connecting:**

```dart
// Recommended: starts Ollama if it isn't running yet, and tells you what's happening.
final ollama = await OllamaClient.connect(onStatus: print);

// Or connect to an Ollama that is already running, on this or another machine.
final remote = OllamaClient(baseUrl: Uri.parse('http://192.168.1.20:11434'));
```

`connect` only starts Ollama when the address is this computer. If the
address belongs to another machine and nothing answers, it stops with a
clear message instead.

**Seeing which models are installed:**

```dart
for (final model in await ollama.listModels()) {
  print('$model  chat: ${model.canChat}  search: ${model.canEmbed}  '
      'thinks: ${model.thinks}  size: ${model.parameterSize}');
}
```

This is handy for a model picker in your app, and for telling users which
model to download.

**Making meaning fingerprints (embeddings):**

```dart
// Many texts at once, with progress for a progress bar.
final vectors = await ollama.embed(
  model: 'all-minilm',
  input: [for (final p in passages) p.text],
  onProgress: (done, total) => print('Indexed $done of $total'),
);

// Just one, such as the user's question.
final question = await ollama.embedOne(model: 'all-minilm', input: 'returns window');
```

Texts are sent in batches of 16. Change that with `batchSize`.

**Getting a whole reply:**

```dart
final reply = await ollama.chat(
  model: 'llama3.2',
  messages: const [
    ChatMessage('system', 'You are a helpful assistant for a shoe shop.'),
    ChatMessage('user', 'Write a one-line welcome message.'),
  ],
  temperature: 0.2, // lower is more predictable, higher is more creative
);
print(reply.content);
```

**Showing the reply as it's written:** for a chat screen, show the words as
they arrive instead of making the user wait for the whole answer:

```dart
final stream = ollama.chatStream(model: 'llama3.2', messages: messages);
await for (final piece in stream) {
  if (piece.thinking != null) stdout.write('(thinking) ');
  if (piece.content != null) stdout.write(piece.content);
}
```

To add a "Stop" button, cancel the stream subscription. That closes the
connection and Ollama stops writing.

**Thinking models** (such as `gpt-oss` or `qwen3`) reason before they
answer, and that reasoning arrives in `thinking`. Pass `think: false` to
`chat` or `chatStream` to skip it and get a faster answer.

**When something goes wrong,** for example Ollama isn't running or the
model isn't downloaded, the methods throw an `OllamaException` whose message
explains the problem. `version()` is the exception: it returns `null`
instead, so you can use it to check whether Ollama is up.

### Starting and stopping Ollama: `OllamaLauncher`

`OllamaClient.connect()` already starts Ollama when it needs to. Use the
launcher directly when you want your own "Start" and "Stop" buttons:

```dart
final ollama = OllamaClient();
final launcher = OllamaLauncher(ollama);

final started = await launcher.ensureRunning(onStatus: print);
if (!started.isUp) {
  print(launcher.explainLaunch(started)); // e.g. how to install Ollama
}

// Later, from a "Stop" button:
final stopped = await launcher.stop(onStatus: print);
final problem = launcher.explainStop(stopped);
if (problem.isNotEmpty) print(problem);
```

Things to know:

- Ollama keeps running after your app quits. That's deliberate, so the
  next launch is instant.
- `stop` also closes the Ollama menu-bar app on macOS, because otherwise it
  starts the server again a second later.
- Starting and stopping works on macOS and Linux. On Windows, start Ollama
  yourself. Everything else in the package works the same.
- A Mac app from the App Store "sandbox" isn't allowed to start other
  programs. To use the launcher in a Mac app, set
  `com.apple.security.app-sandbox` to `false` in its entitlements file.

### Finding the best passages: `SimilarityRanker`

The ranker does the searching for you. Give it your passages once, then ask
it for the best matches to each question:

```dart
final ranker = SimilarityRanker(ollama, model: 'all-minilm');

// Once, when your documents load. Shows progress for a progress bar.
await ranker.addAll(passages, onProgress: (done, total) => print('$done/$total'));

// For each question.
final best = await ranker.rank(
  'How long is the returns window?',
  top: 4,
  maxPerSource: 2,
  minScore: 0.3,
);
for (final match in best) {
  print('${match.score.toStringAsFixed(2)}  ${match.chunk.source}: ${match.chunk.text}');
}
```

`rank` gives you each match with its score and where it came from. When you
only need the text to hand to the chat model, `best.bestPieces` joins it
into one block, best first, with a blank line between pieces.

What each setting means:

| Setting | What it does | Good starting value |
|---|---|---|
| `model` | The search model. Use the same one for as long as you keep the passages. | `all-minilm` |
| `top` | The most passages to return. | 3–6 |
| `maxPerSource` | The most passages to take from any one file. | 2 |
| `minScore` | Leave out passages that are only loosely related. The score runs from 0 (unrelated) to 1 (same meaning). If nothing scores high enough you get an empty list, which is a good cue to answer "I don't know". | about 0.3 with `all-minilm`; leave it out at first |

Why `maxPerSource` matters: a 240-row spreadsheet can produce dozens of
passages that all look a bit like a sales question, and fill the top 5
results by themselves. The policy document that actually answers the
question never gets shown. With `maxPerSource: 2`, other files get a turn.

Each `addAll` asks Ollama to describe the new passages, which takes a moment
for large folders, so call it once rather than for every question. You can
call it again later to add more passages.

### Keeping passages in a database: `VectorStore`

By default the ranker keeps passages in memory (`InMemoryVectorStore`).
That's quick for a few thousand passages, but they're gone when the app
closes, and have to be described again on the next start.

To keep them, store them in a search database such as ObjectBox or
sqlite-vec. Write a class that implements `VectorStore` (adding passages and
finding the closest ones), and hand it to the ranker:

```dart
final ranker = SimilarityRanker(
  ollama,
  model: 'all-minilm',
  store: myDatabaseStore, // implements VectorStore
);
```

Always search with **the same model** you used to fill the store. Each model
makes its own kind of fingerprint, and fingerprints from different models
can't be compared. That's why a store remembers its `embeddingModel`, and
the ranker refuses a store filled by a different model.

If you'd rather compare things yourself, `cosineSimilarity(a, b)` scores two
fingerprints, and `capPerSource(hits, 5, 2)` applies the per-file limit to
any sorted list of results.

## Putting it all together

A typical "answer a question" function tries the exact maths first, then
falls back to searching:

```dart
Future<String> answer(
  String question, {
  required OllamaClient ollama,
  required SimilarityRanker ranker,
  required List<CsvTable> tables,
  List<String> history = const [],
}) async {
  // 1. A calculation over a spreadsheet? Then work it out exactly.
  final figure = TableQueryPlanner.answer(tables, question);

  // 2. Find the passages, using a shortened version of the question.
  final condensed = await QueryCondenser(ollama).condense(
    model: 'llama3.2',
    question: question,
    history: history,
  );
  final hits = await ranker.rank(condensed.text, top: 5, maxPerSource: 2);
  final excerpts = [
    for (final hit in hits) '[${hit.chunk.source}]\n${hit.chunk.text}',
  ].join('\n\n');

  // 3. Ask, with the exact figure (if any) and the passages.
  final reply = await ollama.chat(
    model: 'llama3.2',
    messages: [
      const ChatMessage(
        'system',
        'Answer using only the information below. If a computed figure is '
            'given, use it exactly. If the answer is not there, say so.',
      ),
      ChatMessage('user', [
        if (figure != null) 'Computed figure:\n${figure.toPromptBlock()}',
        'Excerpts:\n$excerpts',
        'Question: $question',
      ].join('\n\n')),
    ],
  );
  return reply.content ?? '';
}
```

Notice that the short, condensed question is used for searching, while the
chat model sees the user's own words.

To index a whole folder, combine the loader, `csvToProse` and the splitter:

```dart
final splitter = RecursiveCharacterTextSplitter();
final tables = <CsvTable>[];
final passages = <Chunk>[];

for (final file in await findSupportedFiles(Directory('knowledge_base'))) {
  final name = file.uri.pathSegments.last;
  var text = await file.readAsString();
  if (fileExtension(name) == '.csv') {
    tables.add(CsvTable.parse(text, source: name)); // for exact maths
    text = csvToProse(text); // for searching
  }
  passages.addAll(splitter.splitText(text, source: name));
}

final ranker = SimilarityRanker(ollama, model: 'all-minilm');
await ranker.addAll(passages);
```

## Choosing settings

**Passage size (`chunkSize`).** The default is 600 characters, about a
paragraph. Smaller passages match short, specific questions better; larger
ones keep more context together. In our tests, going from 1,200 to 600
characters raised the share of short questions that found the right passage
from 6 in 12 to 10 in 12.

| Your documents | Try |
|---|---|
| FAQs, policies, short notes | 300–600 |
| Manuals, reports, articles | 600–1,000 |

**Overlap (`chunkOverlap`).** The default is 200 characters. It must be
smaller than the passage size. Use about a third of the passage size.

**How many passages to send (`top`).** 3 to 6 is usually right. Too few and the
answer may be missing; too many and small models lose focus.

**Models.**

| Job | Small and fast | Better quality |
|---|---|---|
| Searching (embedding) | `all-minilm` | `nomic-embed-text`, `mxbai-embed-large` |
| Answering (chat) | `llama3.2` | `qwen3`, `gpt-oss` |

If you change the embedding model, index your documents again (see
[Keeping passages in a database](#keeping-passages-in-a-database-vectorstore)).

## Where it runs

| | macOS | Linux | Windows |
|---|---|---|---|
| Splitting, CSV, tables, query condenser | ✅ | ✅ | ✅ |
| `OllamaClient` and `findSupportedFiles` | ✅ | ✅ | ✅ |
| `OllamaLauncher` (start / stop) | ✅ | ✅ | ❌ start Ollama yourself |

Web apps aren't supported yet, because parts of the package use features
only available outside the browser.

Flutter on iOS and Android can't run Ollama on the phone itself. Point
`OllamaClient(baseUrl: ...)` at a computer on the same network that runs it.

## Troubleshooting

**"No "ollama" binary found."**
Ollama isn't installed, or it's installed somewhere unusual. Install it from
[ollama.com](https://ollama.com) or with `brew install ollama`. The launcher
looks in the usual install folders, because Mac apps don't see your
terminal's settings.

**"Started … but nothing answered … within 30s."**
Ollama didn't start properly. Run `ollama serve` in a terminal to see why. A
common cause is another program already using port 11434.

**"POST /api/embed failed (404)" or "POST /api/chat failed (404)", mentioning "not found".**
The model isn't downloaded. Run `ollama pull all-minilm` (or whichever model
you named).

**Answers ignore the documents or make things up.**
Print the excerpts you send. If the right passage isn't there, the search
missed it: try a smaller `chunkSize`, use `QueryCondenser`, or raise `top`. If
it's there but the answer is still wrong, make the system message stricter,
or try a larger chat model.

**Answers about totals or averages are wrong.**
Make sure the spreadsheet is passed to `TableQueryPlanner.answer`, and that
the question names a year ("January **2026**"). If it returns `null`, check
that the question uses words from the column name.

**Search results all come from one big file.**
Pass `maxPerSource: 2` to `ranker.rank` (or call `capPerSource` yourself).

**"Ollama stopped, then something started it again."**
It was installed with Homebrew as a background service. Run
`brew services stop ollama`.

## What it doesn't do (yet)

Knowing the limits saves you debugging time:

- **Ollama only.** There is no built-in support for OpenAI, Gemini or other
  hosted AIs yet.
- **Plain-text files only.** PDF, Word and web pages need converting to text
  first.
- **No database included.** The built-in store keeps passages in memory
  only. To keep them between runs, plug in your own database (see
  [Keeping passages in a database](#keeping-passages-in-a-database-vectorstore)).
- **The table planner reads English**, and understands a fixed set of
  words. Unusual phrasing returns `null`, which is safe but means no exact
  figure. A name that isn't in the spreadsheet (like a branch that doesn't
  exist) is ignored rather than rejected, so check `result.query.describe()`
  if a figure looks too large.
- **No web apps.** It runs in command-line tools, servers and Flutter apps,
  but not in a browser.
- **Comma-separated files only.** Files separated by tabs or semicolons
  aren't read correctly yet.

## Words used in this guide

- **RAG**: looking up relevant passages in your documents and giving them to
  the AI before it answers.
- **Embedding / meaning fingerprint**: a list of numbers that captures what a
  piece of text is about. Similar meanings give similar numbers.
- **Embedding model**: the AI model that makes those fingerprints. Small and
  fast; it doesn't write text.
- **Chat model**: the AI model that writes answers.
- **Passage / chunk**: a short piece cut from a document.
- **Overlap**: text repeated from the end of one passage at the start of the
  next.
- **Vector store / vector database**: a place that stores fingerprints and
  quickly finds the ones closest to a question.
- **Thinking model**: a chat model that reasons step by step before
  answering.
