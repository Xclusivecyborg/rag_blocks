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

  group('tool calling', () {
    const calculate = Tool(
      name: 'calculate',
      description: 'Adds up a column.',
      parameters: {
        'type': 'object',
        'properties': {
          'measure': {'type': 'string'},
        },
      },
    );

    test('tools are sent, and tool calls are read back', () async {
      Map? sent;
      final ollama = OllamaClient(
        client: MockClient((req) async {
          sent = jsonDecode(req.body) as Map;
          return http.Response(
            jsonEncode({
              'message': {
                'content': '',
                'tool_calls': [
                  {
                    'function': {
                      'name': 'calculate',
                      'arguments': {'measure': 'revenue'},
                    },
                  },
                ],
              },
              'done': true,
            }),
            200,
          );
        }),
      );
      final reply = await ollama.chat(
        model: 'm',
        messages: messages,
        tools: const [calculate],
      );

      expect(sent!['tools'], [calculate.toJson()]);
      expect(reply.toolCalls.single.name, 'calculate');
      expect(reply.toolCalls.single.arguments, {'measure': 'revenue'});
    });

    test('no tools sends no tools key', () async {
      Map? sent;
      final ollama = OllamaClient(
        client: MockClient((req) async {
          sent = jsonDecode(req.body) as Map;
          return http.Response(
            jsonEncode({
              'message': {'content': 'hi'},
              'done': true,
            }),
            200,
          );
        }),
      );
      await ollama.chat(model: 'm', messages: messages);
      expect(sent!.containsKey('tools'), isFalse);
    });

    test('arguments given as a JSON string are decoded', () {
      final call = ToolCall.fromJson({
        'function': {'name': 'calculate', 'arguments': '{"measure":"units"}'},
      });
      expect(call.arguments, {'measure': 'units'});
    });

    test('a tool result is sent back under the tool role', () {
      const call = ToolCall('calculate', {'measure': 'revenue'});
      final asked = ChatMessage('assistant', '', toolCalls: const [call]);
      final result = ChatMessage.toolResult(call, 'Total: 10');

      expect(asked.toJson()['tool_calls'], [call.toJson()]);
      expect(result.toJson(), {
        'role': 'tool',
        'content': 'Total: 10',
        'tool_name': 'calculate',
      });
      expect(const ChatMessage('user', 'Hi').toJson(), {
        'role': 'user',
        'content': 'Hi',
      }, reason: 'plain messages are unchanged');
    });
  });
}
