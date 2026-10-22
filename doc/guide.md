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

### Better questions, better searches: `QueryCondenser`

**The problem:** the search compares meaning, and everything in the question
counts. "How much discount will I get if I buy shoes worth 100,000 naira as
an employee?" is mostly about shoes and money, so the staff handbook,
which talks about the *employee discount*, ranks far down the list.

Follow-ups are worse. "And the Abuja one?" means nothing by itself.

**The fix:** before searching, ask the chat model to boil the question down
to a few search words, using the conversation so far:

```dart
final condenser = QueryCondenser(ollama.chatModel('llama3.2'));

final first = await condenser.condense(
  question: 'How much discount will I get if I buy shoes worth 100,000 naira '
      'as an employee?',
);
print(first.text); // employee discount policy

final followUp = await condenser.condense(
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

Settings: `QueryCondenser(model, timeout: Duration(seconds: 10))` controls
how long to wait. If you use a "thinking" model (one that reasons before it
answers), pass `ollama.chatModel('qwen3', think: false)` to skip the
reasoning; a rewrite this small doesn't need it.

**Teaching it your documents.** The instructions sent to the model include a
few generic examples. Small models follow examples closely, so examples
from your own documents give better rewrites. Start from the default and
swap the examples:

```dart
final condenser = QueryCondenser(
  ollama.chatModel('llama3.2'),
  systemPrompt: QueryCondenser.defaultSystemPrompt.replaceFirst(
    'Q: Could you please tell me what the warranty covers for the X200 laptop?\n'
        'X200 laptop warranty coverage',
    'Q: What is the returns window for the Heritage line?\n'
        'Heritage line returns window',
  ),
);
```

Whatever you write, keep asking for the query alone on one line. Replies
that add explanations are rejected, and the original question is used.

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

Texts are sent in batches of 16. Change that with `batchSize`, or with
`ollama.embedder('all-minilm', batchSize: 32)` when using the ranker.

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

**Letting the AI call your functions (tool calling):** some questions need
your own code, such as looking up an order or adding up a column over every
row. Describe each function as a `Tool`, with its arguments as a JSON Schema.
The model decides when to use one; its reply then carries `toolCalls`
instead of text. Run each call, send the result back, and ask again:

```dart
final lookup = Tool(
  name: 'order_status',
  description: 'Look up the status of an order by its number.',
  parameters: {
    'type': 'object',
    'required': ['order'],
    'properties': {
      'order': {'type': 'string'},
    },
  },
);

final messages = [ChatMessage('user', 'Where is order 1042?')];
while (true) {
  final reply = await ollama.chat(model: 'gpt-oss', messages: messages, tools: [lookup]);
  if (reply.toolCalls.isEmpty) {
    print(reply.content); // the answer, written with the results
    break;
  }
  messages.add(ChatMessage('assistant', reply.content ?? '', toolCalls: reply.toolCalls));
  for (final call in reply.toolCalls) {
    messages.add(ChatMessage.toolResult(call, statusOf(call.arguments['order'])));
  }
}
```

Tool calls also arrive through `chatStream`, in the piece's `toolCalls`. Not
every model supports tools: `gpt-oss`, `llama3.1` and newer, and `qwen3` do.
Check the arguments before you trust them. Models misspell names and leave
out fields, so return a message saying what's wrong, and the model can try
again. Put a limit on the rounds, too, so a confused model can't loop
forever. If a model writes a tool call that isn't valid JSON, Ollama replies
with an error containing "error parsing tool call"; tell the model and ask
again.

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
- `stop` also closes the Ollama menu-bar app on macOS, or the tray app on
  Windows, because otherwise it starts the server again a second later.
- Starting and stopping works on macOS, Linux and Windows. On Windows it
  looks for `ollama.exe` where the official installer puts it, then in
  Program Files, then anywhere on your PATH.
- A Mac app from the App Store "sandbox" isn't allowed to start other
  programs. To use the launcher in a Mac app, set
  `com.apple.security.app-sandbox` to `false` in its entitlements file.

### Finding the best passages: `SimilarityRanker`

The ranker does the searching for you. Give it your passages once, then ask
it for the best matches to each question:

```dart
final ranker = SimilarityRanker(ollama.embedder('all-minilm'));

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
| embedder | The search model, such as `ollama.embedder('all-minilm')`. Use the same one for as long as you keep the passages. | `all-minilm` |
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
  ollama.embedder('all-minilm'),
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

### Using a model that isn't Ollama: `Embedder` and `ChatModel`

The ranker and the condenser don't need Ollama itself, only something that
can do their one job:

- The ranker needs an **`Embedder`**: something that turns texts into
  fingerprints.
- The condenser needs a **`ChatModel`**: something that writes a reply to a
  conversation.

`ollama.embedder(...)` and `ollama.chatModel(...)` give you Ollama's. To use
another model, write a small class for it. This is how the package works on
**phones**, where Ollama can't run: wrap an on-device model, such as one
from a llama.cpp, Gemma or ONNX plugin.

```dart
class PhoneEmbedder implements Embedder {
  PhoneEmbedder(this.plugin);
  final MyOnDeviceModel plugin; // whatever your plugin provides

  @override
  String get model => 'all-minilm-onnx'; // any name; it labels the fingerprints

  @override
  Future<List<List<double>>> embed(
    List<String> texts, {
    void Function(int done, int total)? onProgress,
  }) async {
    final vectors = <List<double>>[];
    for (final text in texts) {
      vectors.add(await plugin.embed(text));
      onProgress?.call(vectors.length, texts.length);
    }
    return vectors;
  }
}

class PhoneChat implements ChatModel {
  PhoneChat(this.plugin);
  final MyOnDeviceModel plugin;

  @override
  Future<String> reply(List<ChatMessage> messages, {double temperature = 0.2}) =>
      plugin.generate(messages, temperature: temperature);
}

final ranker = SimilarityRanker(PhoneEmbedder(plugin));
final condenser = QueryCondenser(PhoneChat(plugin));
```

The same goes for a hosted AI service: wrap its API in an `Embedder` or a
`ChatModel`, and the rest of the package works unchanged.

## Putting it all together

A typical "answer a question" function shortens the question, searches with
it, and asks the chat model:

```dart
Future<String> answer(
  String question, {
  required OllamaClient ollama,
  required SimilarityRanker ranker,
  List<String> history = const [],
}) async {
  // 1. Find the passages, using a shortened version of the question.
  final condensed = await QueryCondenser(ollama.chatModel('llama3.2')).condense(
    question: question,
    history: history,
  );
  final hits = await ranker.rank(condensed.text, top: 5, maxPerSource: 2);
  final excerpts = [
    for (final hit in hits) '[${hit.chunk.source}]\n${hit.chunk.text}',
  ].join('\n\n');

  // 2. Ask, with the passages.
  final reply = await ollama.chat(
    model: 'llama3.2',
    messages: [
      const ChatMessage(
        'system',
        'Answer using only the excerpts below. If the answer is not there, '
            'say so.',
      ),
      ChatMessage('user', 'Excerpts:\n$excerpts\n\nQuestion: $question'),
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
final passages = <Chunk>[];

for (final file in await findSupportedFiles(Directory('knowledge_base'))) {
  final name = file.uri.pathSegments.last;
  var text = await file.readAsString();
  if (fileExtension(name) == '.csv') text = csvToProse(text);
  passages.addAll(splitter.splitText(text, source: name));
}

final ranker = SimilarityRanker(ollama.embedder('all-minilm'));
await ranker.addAll(passages);
```

Searching is the wrong tool for totals and averages over a spreadsheet: it
hands the AI a few rows, and the AI adds up that sample. Instead, give the AI
a tool that works out the figure in your own code over every row (see
[Talking to the AI](#talking-to-the-ai-ollamaclient)).

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

| | macOS | Linux | Windows | iOS | Android |
|---|---|---|---|---|---|
| Splitting, CSV, tables | ✅ | ✅ | ✅ | ✅ | ✅ |
| Ranker and condenser | ✅ | ✅ | ✅ | ✅ | ✅ |
| `findSupportedFiles` | ✅ | ✅ | ✅ | ✅ (app's own folders) | ✅ (app's own folders) |
| `OllamaClient` | ✅ | ✅ | ✅ | ✅ (Ollama on another computer) | ✅ (Ollama on another computer) |
| `OllamaLauncher` (start / stop) | ✅ | ✅ | ✅ | ❌ | ❌ |

Web apps aren't supported yet, because parts of the package use features
only available outside the browser.

**On phones**, Ollama can't run on the phone itself. You have two options:

- **A model on the phone.** Wrap it in an `Embedder` and a `ChatModel` (see
  [Using a model that isn't Ollama](#using-a-model-that-isnt-ollama-embedder-and-chatmodel)).
  Everything works offline.
- **Ollama on another computer.** Use
  `OllamaClient(baseUrl: Uri.parse('http://192.168.1.20:11434'))`, and start
  Ollama there with `OLLAMA_HOST=0.0.0.0 ollama serve` so it accepts
  connections from the network. Phones block plain `http://` addresses by
  default: allow them in the app's settings (`NSAppTransportSecurity` on
  iOS, a network security config on Android). iOS also asks the user for
  Local Network permission.

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
The search only hands the AI a few rows, so it adds up a sample. Work the
figure out in your own code over every row instead, and let the AI ask for it
through tool calling (see [Talking to the AI](#talking-to-the-ai-ollamaclient)).

**Search results all come from one big file.**
Pass `maxPerSource: 2` to `ranker.rank` (or call `capPerSource` yourself).

**"Ollama stopped, then something started it again."**
It was installed with Homebrew as a background service. Run
`brew services stop ollama`.

## What it doesn't do (yet)

Knowing the limits saves you debugging time:

- **Ollama is the only model built in.** For OpenAI, Gemini, an on-device
  model or anything else, write a small `Embedder` or `ChatModel` (see
  [Using a model that isn't Ollama](#using-a-model-that-isnt-ollama-embedder-and-chatmodel)).
- **Plain-text files only.** PDF, Word and web pages need converting to text
  first.
- **No database included.** The built-in store keeps passages in memory
  only. To keep them between runs, plug in your own database (see
  [Keeping passages in a database](#keeping-passages-in-a-database-vectorstore)).
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
- **Tool calling**: letting the chat model ask your code to run a function,
  and answer with the result.
