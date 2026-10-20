import 'dart:async';

import '../llms/chat_model.dart';
import '../llms/ollama_client.dart';

/// The result of trying to shorten a question before embedding it.
class CondensedQuery {
  const CondensedQuery({
    required this.text,
    required this.original,
    required this.wasCondensed,
    this.note,
  });

  const CondensedQuery.unchanged(String question, [String? why])
    : text = question,
      original = question,
      wasCondensed = false,
      note = why;

  final String text; // what to embed
  final String original;
  final bool wasCondensed;
  final String? note; // why the rewrite was skipped or rejected
}

/// Rewrites a question into a short search query before it is embedded.
///
/// An embedding represents the whole sentence, so extra clauses pull it
/// off-topic. On the test knowledge base, "employee discount" finds the
/// staff handbook at rank 1, but a long question about buying shoes as an
/// employee ranks it 10th. Condensing also turns follow-ups like "and for
/// contractors?" into a real query using the conversation so far.
///
/// Every failure falls back to the original question: a bad rewrite is worse
/// than none.
class QueryCondenser {
  QueryCondenser(
    this._ollama, {
    this.timeout = const Duration(seconds: 25),
    this.systemPrompt = defaultSystemPrompt,
  });

  final OllamaClient _ollama;
  final Duration timeout;

  /// The instructions given to the chat model. Replace it to add examples
  /// from your own documents, which helps a small model most. Keep asking for
  /// the query alone on one line: anything else is rejected.
  final String systemPrompt;

  /// Shorter questions are already close to a search query.
  static const int minWordsToCondense = 8;

  /// A longer rewrite is the model explaining itself, not a query.
  static const int maxWords = 12;

  /// The default [systemPrompt]. Its examples are deliberately generic.
  static const String defaultSystemPrompt = '''
You rewrite questions into short search queries for a document search engine.

Rules:
- Output ONLY the query. No preamble, no quotes, no explanation.
- Keep the words that identify WHICH document or topic is needed.
- Drop politeness, hypotheticals, and any numbers the user wants calculated.
- Use the conversation to resolve pronouns and follow-ups into full nouns.
- Maximum 8 words.

Examples:
Q: How many days of annual leave would I have left if I took 6 days off in March?
annual leave allowance
Conversation so far:
What is the annual leave policy?
Q: and for contractors?
contractor annual leave policy
Q: Could you please tell me what the warranty covers for the X200 laptop?
X200 laptop warranty coverage''';

  /// Returns the query to embed. Never throws.
  Future<CondensedQuery> condense({
    required String model,
    required String question,
    List<String> history = const [],
    bool thinkingModel = false,
  }) async {
    final trimmed = question.trim();
    if (trimmed.isEmpty) return const CondensedQuery.unchanged('');

    final words = trimmed.split(RegExp(r'\s+')).length;
    if (words < minWordsToCondense && history.isEmpty) {
      return CondensedQuery.unchanged(trimmed, 'short question, left alone');
    }

    final messages = [
      ChatMessage('system', systemPrompt),
      ChatMessage(
        'user',
        history.isEmpty
            ? 'Q: $trimmed'
            : 'Conversation so far:\n${history.join('\n')}\n\nQ: $trimmed',
      ),
    ];

    try {
      // A one-line rewrite is only useful whole, so it is not streamed.
      final reply = await _ollama
          .chat(
            model: model,
            messages: messages,
            temperature: 0,
            // A one-line rewrite does not need seconds of visible thinking.
            think: thinkingModel ? false : null,
          )
          .timeout(timeout);
      return _validate(reply.content ?? '', trimmed);
    } on Object catch (e) {
      return CondensedQuery.unchanged(trimmed, 'condense failed: $e');
    }
  }

  /// Accepts the rewrite only if it looks like a search query.
  static CondensedQuery _validate(String raw, String original) {
    if (raw.trim().isEmpty) {
      return CondensedQuery.unchanged(original, 'empty rewrite');
    }

    // Take the first non-empty line, without quotes or a "Query:" label.
    var text = raw
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    text = text.replaceAll(RegExp(r'^["“”\x27`]+|["“”\x27`]+$'), '').trim();
    text = text.replaceFirst(
      RegExp(r'^(query|search|answer)\s*:\s*', caseSensitive: false),
      '',
    );

    if (text.isEmpty) {
      return CondensedQuery.unchanged(original, 'empty after cleanup');
    }
    if (text.split(RegExp(r'\s+')).length > maxWords) {
      return CondensedQuery.unchanged(original, 'rewrite too long');
    }
    if (RegExp(
      r"\b(sorry|cannot|can't|unable|as an ai)\b",
      caseSensitive: false,
    ).hasMatch(text)) {
      return CondensedQuery.unchanged(original, 'model refused');
    }
    final meaningfulWords = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((w) => w.length > 2 && !_stopwords.contains(w));
    if (meaningfulWords.isEmpty) {
      return CondensedQuery.unchanged(original, 'rewrite carried no content');
    }

    return CondensedQuery(text: text, original: original, wasCondensed: true);
  }

  static const Set<String> _stopwords = {
    'the',
    'and',
    'for',
    'with',
    'what',
    'how',
    'why',
    'who',
    'was',
    'are',
    'you',
    'your',
    'this',
    'that',
    'from',
    'about',
    'get',
    'can',
    'does',
  };
}
