import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ollama_launcher.dart';

/// A model already downloaded to this machine.
class OllamaModel {
  OllamaModel({
    required this.name,
    required this.capabilities,
    this.parameterSize,
  });

  final String name;
  final List<String> capabilities;
  final String? parameterSize; // e.g. "20B", shown in the model picker

  bool get canChat => capabilities.contains('completion');

  /// Read from `capabilities`, not `embedding_length`: chat models report an
  /// embedding length too, but cannot be used as embedders.
  bool get canEmbed => capabilities.contains('embedding');

  /// Reasoning models stream a separate `thinking` field before the answer.
  bool get thinks => capabilities.contains('thinking');

  factory OllamaModel.fromJson(Map<String, dynamic> json) {
    final details = (json['details'] as Map<String, dynamic>?) ?? const {};
    return OllamaModel(
      name: json['name'] as String,
      capabilities:
          (json['capabilities'] as List?)?.cast<String>() ?? const <String>[],
      parameterSize: details['parameter_size'] as String?,
    );
  }

  @override
  String toString() => name;
}

class ChatMessage {
  const ChatMessage(this.role, this.content);
  final String role; // 'system', 'user' or 'assistant'
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// One streamed piece of a chat reply.
class ChatChunk {
  const ChatChunk({this.content, this.thinking});
  final String? content;
  final String? thinking;
}

class OllamaException implements Exception {
  OllamaException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A small client for Ollama's HTTP API on localhost.
class OllamaClient {
  OllamaClient({Uri? baseUrl, http.Client? client})
    : baseUrl = baseUrl ?? Uri.parse('http://127.0.0.1:11434'),
      _client = client ?? http.Client();

  final Uri baseUrl;
  final http.Client _client;

  /// A client for a running Ollama, starting `ollama serve` first if nothing
  /// is answering. The one call most code needs:
  ///
  /// ```dart
  /// final ollama = await OllamaClient.connect();
  /// final vector = await ollama.embedOne(model: 'all-minilm', input: 'hi');
  /// ```
  ///
  /// Throws [OllamaException] with a readable reason (not installed, would
  /// not start, never answered) when Ollama cannot be reached.
  static Future<OllamaClient> connect({
    Uri? baseUrl,
    void Function(String message)? onStatus,
  }) async {
    final client = OllamaClient(baseUrl: baseUrl);
    final launcher = OllamaLauncher(client);
    final outcome = await launcher.ensureRunning(onStatus: onStatus);
    if (!outcome.isUp) {
      client.close();
      throw OllamaException(launcher.explainLaunch(outcome));
    }
    return client;
  }

  /// mxbai-embed-large expects this prefix on search queries, not on
  /// documents. On the test knowledge base it made no measurable difference.
  static const String mxbaiQueryPrefix =
      'Represent this sentence for searching relevant passages: ';

  /// The installed Ollama version, or null if Ollama is not reachable.
  /// Never throws, because it is polled while Ollama starts.
  Future<String?> version({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final res = await _client
          .get(baseUrl.resolve('/api/version'))
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      return (jsonDecode(res.body) as Map<String, dynamic>)['version']
          as String?;
    } on Object {
      return null;
    }
  }

  /// Installed models, sorted by name.
  Future<List<OllamaModel>> listModels() async {
    final http.Response res;
    try {
      res = await _client
          .get(baseUrl.resolve('/api/tags'))
          .timeout(const Duration(seconds: 10));
    } on Object catch (e) {
      throw OllamaException(
        'Could not reach Ollama at $baseUrl.\n'
        'Is it running? Try: ollama serve\n\n$e',
      );
    }
    if (res.statusCode != 200) {
      throw OllamaException('GET /api/tags failed (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['models'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(OllamaModel.fromJson)
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Embeds [input] in batches. Returns one vector per input, in order.
  Future<List<List<double>>> embed({
    required String model,
    required List<String> input,
    int batchSize = 16,
    void Function(int done, int total)? onProgress,
  }) async {
    final vectors = <List<double>>[];
    for (var i = 0; i < input.length; i += batchSize) {
      final batch = input.sublist(i, (i + batchSize).clamp(0, input.length));
      final http.Response res;
      try {
        res = await _client
            .post(
              baseUrl.resolve('/api/embed'),
              headers: const {'Content-Type': 'application/json'},
              body: jsonEncode({'model': model, 'input': batch}),
            )
            .timeout(const Duration(minutes: 5));
      } on Object catch (e) {
        throw OllamaException('Embedding request failed: $e');
      }
      if (res.statusCode != 200) {
        throw OllamaException(
          'POST /api/embed failed (${res.statusCode}): ${res.body}',
        );
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final batchVectors = (body['embeddings'] as List?)?.cast<List>();
      if (batchVectors == null || batchVectors.length != batch.length) {
        throw OllamaException(
          'Expected ${batch.length} embeddings, got ${batchVectors?.length}',
        );
      }
      for (final v in batchVectors) {
        vectors.add([for (final x in v) (x as num).toDouble()]);
      }
      onProgress?.call(vectors.length, input.length);
    }
    return vectors;
  }

  Future<List<double>> embedOne({
    required String model,
    required String input,
  }) async => (await embed(model: model, input: [input])).first;

  /// Sends a chat and waits for the whole reply, like Python's
  /// `ollama.chat()`:
  ///
  /// ```dart
  /// final reply = await ollama.chat(model: 'gpt-oss', messages: messages);
  /// print(reply.content);
  /// ```
  ///
  /// Use [chatStream] to show the reply as it is written instead. Set [think]
  /// to false to skip a reasoning model's thinking.
  Future<ChatChunk> chat({
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.2,
    bool? think,
  }) async {
    final res = await _sendChat(model, messages, temperature, think, false);
    final json = jsonDecode(await res.stream.bytesToString());
    return _chunkFrom(json as Map<String, dynamic>) ?? const ChatChunk();
  }

  /// Sends a chat and streams the reply piece by piece as the model writes
  /// it, like Python's `ollama.chat(stream=True)`. Ollama sends one JSON
  /// object per line.
  ///
  /// Cancelling the subscription closes the connection, which stops
  /// generation. Set [think] to false to skip a reasoning model's thinking.
  Stream<ChatChunk> chatStream({
    required String model,
    required List<ChatMessage> messages,
    double temperature = 0.2,
    bool? think,
  }) async* {
    final res = await _sendChat(model, messages, temperature, think, true);
    final lines = res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final Map<String, dynamic> json;
      try {
        json = jsonDecode(line) as Map<String, dynamic>;
      } on FormatException {
        continue; // keep-alive or partial line
      }
      final chunk = _chunkFrom(json);
      if (chunk != null) yield chunk;
      if (json['done'] == true) return;
    }
  }

  /// POSTs to /api/chat and returns the response once it starts, or throws.
  Future<http.StreamedResponse> _sendChat(
    String model,
    List<ChatMessage> messages,
    double temperature,
    bool? think,
    bool stream,
  ) async {
    final req = http.Request('POST', baseUrl.resolve('/api/chat'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'model': model,
        'messages': [for (final m in messages) m.toJson()],
        'stream': stream,
        'options': {'temperature': temperature},
        'think': ?think,
      });

    final http.StreamedResponse res;
    try {
      res = await _client.send(req);
    } on Object catch (e) {
      throw OllamaException('Could not reach Ollama at $baseUrl: $e');
    }
    if (res.statusCode != 200) {
      final body = await res.stream.bytesToString();
      throw OllamaException('POST /api/chat failed (${res.statusCode}): $body');
    }
    return res;
  }

  /// The content of one reply object, or null if it carries no text.
  static ChatChunk? _chunkFrom(Map<String, dynamic> json) {
    if (json['error'] != null) {
      throw OllamaException('Ollama error: ${json['error']}');
    }
    final message = json['message'] as Map<String, dynamic>?;
    final content = message?['content'] as String?;
    final thinking = message?['thinking'] as String?;
    if ((content?.isNotEmpty ?? false) || (thinking?.isNotEmpty ?? false)) {
      return ChatChunk(content: content, thinking: thinking);
    }
    return null;
  }

  void close() => _client.close();
}
