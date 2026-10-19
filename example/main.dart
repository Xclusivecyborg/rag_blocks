// A whole RAG pipeline in one file: split, embed, search, answer.
//
//   dart run example/main.dart
//
// Needs Ollama installed, plus:
//   ollama pull all-minilm
//   ollama pull llama3.2
//
// The vector store here is a plain list, which is fine for a few hundred
// chunks. Implement VectorStore over ObjectBox or sqlite-vec for more.

import 'dart:math' as math;

import 'package:rag_blocks/rag_blocks.dart';

const embedModel = 'all-minilm';
const chatModel = 'llama3.2';

const handbook = '''
Customers may return unworn footwear within 21 days of purchase for a full
refund. The Heritage line carries an extended 45-day returns window.

Full-time employees accrue 20 working days of paid annual leave per year.
All employees receive a 40% discount on the Everyday line.''';

Future<void> main() async {
  // 1. Connect, starting `ollama serve` if it is not running.
  final ollama = await OllamaClient.connect(onStatus: print);

  // 2. Split the document into chunks.
  final splitter = RecursiveCharacterTextSplitter(
    chunkSize: 200,
    chunkOverlap: 40,
  );
  final chunks = splitter.splitText(handbook, source: 'handbook.md');

  // 3. Embed every chunk.
  final vectors = await ollama.embed(
    model: embedModel,
    input: [for (final c in chunks) c.text],
  );

  // 4. Embed the question and find the closest chunks.
  const question = 'How long do I have to return Heritage shoes?';
  final query = await ollama.embedOne(model: embedModel, input: question);
  final ranked = [
    for (var i = 0; i < chunks.length; i++)
      (chunk: chunks[i], score: _cosine(query, vectors[i])),
  ]..sort((a, b) => b.score.compareTo(a.score));
  final context = ranked.take(2).map((r) => r.chunk.text).join('\n\n');

  // 5. Answer from those chunks only.
  final reply = await ollama.chat(
    model: chatModel,
    messages: [
      const ChatMessage(
        'system',
        'Answer using only the excerpts. If they do not say, reply '
            '"I don\'t know."',
      ),
      ChatMessage('user', 'Excerpts:\n$context\n\nQuestion: $question'),
    ],
  );
  print(reply.content);
  ollama.close();
}

double _cosine(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}
