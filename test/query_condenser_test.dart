import 'dart:convert';

import 'package:test/test.dart';
import 'package:rag_blocks/rag_blocks.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A client whose /api/chat answers [reply] the way Ollama does: as NDJSON
/// pieces when streaming, as one JSON object when not.
OllamaClient clientReplying(String reply) => OllamaClient(
  client: MockClient.streaming((req, bodyStream) async {
    final request = jsonDecode(await bodyStream.bytesToString()) as Map;
    final body = request['stream'] == false
        ? jsonEncode({
            'message': {'content': reply},
            'done': true,
          })
        : [
            for (final piece in reply.split(''))
              jsonEncode({
                'message': {'content': piece},
                'done': false,
              }),
            jsonEncode({'done': true}),
          ].join('\n');
    return http.StreamedResponse(Stream.fromIterable([utf8.encode(body)]), 200);
  }),
);

OllamaClient clientThatFails() =>
    OllamaClient(client: MockClient((req) async => http.Response('boom', 500)));

const long =
    'How much will I get as discount if I purchase shoes worth '
    '100,000 naira as an employee of stridewell?';

void main() {
  Future<CondensedQuery> run(
    OllamaClient c,
    String question, {
    List<String> history = const [],
  }) => QueryCondenser(
    c,
  ).condense(model: 'test', question: question, history: history);

  group('when to bother', () {
    test('a short question is left completely alone', () async {
      // No model call at all: nothing to gain, and a rewrite could strip the
      // one word that mattered.
      final r = await run(clientThatFails(), 'employee discount');
      expect(r.wasCondensed, isFalse);
      expect(r.text, 'employee discount');
      expect(r.note, contains('short question'));
    });

    test(
      'a short follow-up IS condensed, because history resolves it',
      () async {
        final r = await run(
          clientReplying('Abuja branch location'),
          'and the Abuja one?',
          history: ['user: Where is the Lagos branch?'],
        );
        expect(r.wasCondensed, isTrue);
        expect(r.text, 'Abuja branch location');
      },
    );

    test('a long question is condensed', () async {
      final r = await run(clientReplying('employee discount policy'), long);
      expect(r.wasCondensed, isTrue);
      expect(r.text, 'employee discount policy');
      expect(r.original, long);
    });

    test('an empty question does not explode', () async {
      final r = await run(clientThatFails(), '   ');
      expect(r.text, isEmpty);
      expect(r.wasCondensed, isFalse);
    });
  });

  group('a rewrite is only used if it looks like a query', () {
    test('surrounding quotes are stripped', () async {
      final r = await run(clientReplying('"employee discount policy"'), long);
      expect(r.text, 'employee discount policy');
    });

    test('a Query: label is stripped', () async {
      final r = await run(clientReplying('Query: employee discount'), long);
      expect(r.text, 'employee discount');
    });

    test('trailing commentary is dropped, first line wins', () async {
      final r = await run(
        clientReplying('employee discount policy\n\nI removed the amount.'),
        long,
      );
      expect(r.text, 'employee discount policy');
    });

    test('an over-long rewrite is rejected', () async {
      final r = await run(
        clientReplying(
          'the user is asking about the employee discount '
          'policy and how it applies to a purchase of one hundred thousand',
        ),
        long,
      );
      expect(r.wasCondensed, isFalse);
      expect(r.text, long, reason: 'must fall back to the original');
      expect(r.note, contains('too long'));
    });

    test('a refusal is rejected', () async {
      final r = await run(clientReplying("Sorry, I cannot do that"), long);
      expect(r.wasCondensed, isFalse);
      expect(r.text, long);
      expect(r.note, contains('refused'));
    });

    test('a rewrite of pure stopwords is rejected', () async {
      final r = await run(clientReplying('what about the'), long);
      expect(r.wasCondensed, isFalse);
      expect(r.text, long);
      expect(r.note, contains('no content'));
    });

    test('an empty rewrite is rejected', () async {
      final r = await run(clientReplying('   \n  '), long);
      expect(r.wasCondensed, isFalse);
      expect(r.text, long);
    });
  });

  group('failure never costs the turn', () {
    test('a dead model falls back to the raw question', () async {
      final r = await run(clientThatFails(), long);
      expect(r.wasCondensed, isFalse);
      expect(r.text, long);
      expect(r.note, contains('condense failed'));
    });

    test('a timeout falls back to the raw question', () async {
      // Finite but far slower than the condenser's timeout — an infinite
      // stream would outlive the assertion and hang the test runner.
      final hanging = OllamaClient(
        client: MockClient.streaming(
          (req, body) async => http.StreamedResponse(
            Stream<List<int>>.fromFuture(
              Future<List<int>>.delayed(
                const Duration(seconds: 3),
                () => const <int>[],
              ),
            ),
            200,
          ),
        ),
      );
      final r = await QueryCondenser(
        hanging,
        timeout: const Duration(milliseconds: 300),
      ).condense(model: 'test', question: long);
      expect(r.wasCondensed, isFalse);
      expect(r.text, long);
    });
  });
}
