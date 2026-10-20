// Teaches a local AI a two-paragraph shop handbook, then asks it a question.
// This is the quick start from the README as one file.
//
//   dart run example/main.dart
//
// Needs Ollama installed, plus:
//   ollama pull all-minilm
//   ollama pull llama3.2

import 'package:rag_blocks/rag_blocks.dart';

const handbook = '''
Customers may return unworn footwear within 21 days of purchase for a full
refund. The Heritage line carries an extended 45-day returns window.

Full-time employees accrue 20 working days of paid annual leave per year.
All employees receive a 40% discount on the Everyday line.''';

Future<void> main() async {
  // Step 1: connect to Ollama, starting it if it is not running.
  final ollama = await OllamaClient.connect(onStatus: print);

  // Step 2: cut the handbook into small pieces.
  final splitter = RecursiveCharacterTextSplitter(
    chunkSize: 200,
    chunkOverlap: 40,
  );
  final pieces = splitter.splitText(handbook, source: 'handbook.md');

  // Step 3: find the pieces that best match the question.
  final ranker = SimilarityRanker(ollama.embedder('all-minilm'));
  await ranker.addAll(pieces);
  const question = 'How long do I have to return Heritage shoes?';
  final bestPieces = (await ranker.rank(question, top: 2)).bestPieces;

  // Step 4: ask the chat model, giving it only those pieces.
  final reply = await ollama.chat(
    model: 'llama3.2',
    messages: [
      const ChatMessage(
        'system',
        'Answer using only the excerpts. If they do not say, reply '
            '"I don\'t know."',
      ),
      ChatMessage('user', 'Excerpts:\n$bestPieces\n\nQuestion: $question'),
    ],
  );
  print(reply.content);
  ollama.close();
}
