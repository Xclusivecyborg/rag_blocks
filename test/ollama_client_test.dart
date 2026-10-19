import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:test/test.dart';

/// Answers /api/chat like Ollama, and records whether streaming was asked for.
OllamaClient fakeOllama(List<bool> streamRequested) => OllamaClient(
  client: MockClient.streaming((req, bodyStream) async {
    final request = jsonDecode(await bodyStream.bytesToString()) as Map;
    final stream = request['stream'] as bool;
    streamRequested.add(stream);
    final body = stream
        ? [
            for (final piece in ['Hel', 'lo', '!'])
              jsonEncode({
                'message': {'content': piece},
                'done': false,
              }),
            jsonEncode({'done': true}),
          ].join('\n')
        : jsonEncode({
            'message': {'content': 'Hello!'},
            'done': true,
          });
    return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
  }),
);

const messages = [ChatMessage('user', 'Hi')];

void main() {
  test('chatStream streams the reply piece by piece', () async {
    final asked = <bool>[];
    final pieces = await fakeOllama(
      asked,
    ).chatStream(model: 'm', messages: messages).map((c) => c.content).toList();

    expect(asked, [true]);
    expect(pieces, ['Hel', 'lo', '!']);
  });

  test('chat waits for the whole reply', () async {
    final asked = <bool>[];
    final reply = await fakeOllama(asked).chat(model: 'm', messages: messages);

    expect(asked, [false]);
    expect(reply.content, 'Hello!');
  });

  test('an error in a whole reply is thrown, not swallowed', () async {
    final ollama = OllamaClient(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode({'error': 'model not found'}), 200),
      ),
    );
    expect(
      ollama.chat(model: 'm', messages: messages),
      throwsA(isA<OllamaException>()),
    );
  });

  test('embed rejects a non-positive batch size instead of looping', () {
    expect(
      () => fakeOllama([]).embed(model: 'm', input: ['a'], batchSize: 0),
      throwsArgumentError,
    );
  });
}
