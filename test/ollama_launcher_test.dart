import 'dart:io';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rag_blocks/rag_blocks.dart';

/// Covers the paths a working machine never reaches: no binary anywhere, the
/// spawn failing, and `ollama serve` starting but never answering.
/// No real Ollama, no real process.
void main() {
  /// A client whose /api/version answers only once [up] returns true.
  OllamaClient clientThatIsUp(bool Function() up) => OllamaClient(
    client: MockClient((req) async {
      if (req.url.path == '/api/version') {
        return up()
            ? http.Response('{"version":"0.32.5"}', 200)
            : http.Response('nope', 500);
      }
      return http.Response('{}', 404);
    }),
  );

  OllamaLauncher launcher({
    required bool Function() up,
    List<String>? searchPaths,
    OllamaSpawn? spawn,
  }) => OllamaLauncher(
    clientThatIsUp(up),
    // A path that always exists, so "found the binary" is not the variable
    // under test — Platform.resolvedExecutable is the running dart binary.
    searchPaths: searchPaths ?? <String>[Platform.resolvedExecutable],
    spawn: spawn ?? (_) async => 4242,
    startupTimeout: const Duration(milliseconds: 600),
    pollInterval: const Duration(milliseconds: 50),
  );

  test('already running: does not spawn anything', () async {
    var spawned = false;
    final l = launcher(
      up: () => true,
      spawn: (_) async {
        spawned = true;
        return 4242;
      },
    );

    final outcome = await l.ensureRunning();

    expect(outcome, LaunchOutcome.alreadyRunning);
    expect(outcome.isUp, isTrue);
    // The important assertion: a healthy Ollama is left completely alone.
    expect(spawned, isFalse);
  });

  test('spawns ollama serve, then polls until it answers', () async {
    var up = false;
    String? ranExecutable;

    final l = launcher(
      up: () => up,
      spawn: (executable) async {
        ranExecutable = executable;
        // The server is not listening the instant the process exists.
        Future<void>.delayed(
          const Duration(milliseconds: 120),
          () => up = true,
        );
        return 4242;
      },
    );

    final status = <String>[];
    final outcome = await l.ensureRunning(onStatus: status.add);

    expect(outcome, LaunchOutcome.started);
    expect(ranExecutable, Platform.resolvedExecutable);
    expect(status.first, 'Starting ollama serve…');
  });

  test('no binary anywhere is reported as not installed', () async {
    final l = launcher(
      up: () => false,
      searchPaths: <String>['/nowhere/ollama', '/also/nowhere/ollama'],
    );

    final outcome = await l.ensureRunning();

    expect(outcome, LaunchOutcome.notInstalled);
    expect(l.resolvedPath, isNull);
    expect(l.explainLaunch(outcome), contains('brew install ollama'));
  });

  test('a dangling symlink does not count as installed', () async {
    // Exactly what deleting Ollama.app leaves behind at /usr/local/bin/ollama.
    final dir = Directory.systemTemp.createTempSync('launcher_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final link = Link('${dir.path}/ollama')
      ..createSync('${dir.path}/gone/ollama');

    final l = launcher(up: () => false, searchPaths: <String>[link.path]);

    expect(await l.ensureRunning(), LaunchOutcome.notInstalled);
  });

  test('a failing spawn is reported, with the underlying reason', () async {
    final l = launcher(
      up: () => false,
      spawn: (_) async => throw const ProcessException('ollama', <String>[
        'serve',
      ], 'Permission denied'),
    );

    final outcome = await l.ensureRunning();

    expect(outcome, LaunchOutcome.launchFailed);
    expect(l.explainLaunch(outcome), contains('Permission denied'));
  });

  test('timeout tells the user how to see the real error', () async {
    // A detached process gives us no stderr, so the message has to hand the
    // problem back to the terminal rather than pretend to diagnose it.
    final l = launcher(up: () => false);
    expect(l.explainLaunch(await l.ensureRunning()), contains('ollama serve'));
  });

  test('started but never answering times out', () async {
    final l = launcher(up: () => false);

    final sw = Stopwatch()..start();
    final outcome = await l.ensureRunning();
    sw.stop();

    expect(outcome, LaunchOutcome.timedOut);
    expect(outcome.isUp, isFalse);
    // It waited rather than giving up on the first failed poll.
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(500));
    expect(l.explainLaunch(outcome), contains('port 11434'));
  });

  test('explain() is silent only when we are actually up', () {
    final l = launcher(up: () => true);
    for (final outcome in LaunchOutcome.values) {
      expect(
        l.explainLaunch(outcome).isEmpty,
        outcome.isUp,
        reason: '$outcome',
      );
    }
  });

  group('stop', () {
    /// Records every command run, and reports the port dead once killed.
    ({OllamaLauncher launcher, List<List<String>> commands}) stoppable({
      required bool diesOnTerm,
      List<int> pgrepPids = const <int>[9001],
      List<int> appPids = const <int>[],
      bool restartsAfterDeath = false,
    }) {
      final commands = <List<String>>[];
      var serving = true;

      final l = OllamaLauncher(
        clientThatIsUp(() => serving),
        searchPaths: <String>[Platform.resolvedExecutable],
        spawn: (_) async => 4242,
        run: (exe, args) async {
          commands.add(<String>[exe, ...args]);
          if (exe.endsWith('pgrep')) {
            final found = args.last == OllamaLauncher.menuBarAppPattern
                ? appPids
                : pgrepPids;
            return ProcessResult(
              0,
              found.isEmpty ? 1 : 0,
              found.join('\n'),
              '',
            );
          }
          if (exe.endsWith('kill')) {
            final forced = args.first == '-KILL';
            if (diesOnTerm || forced) {
              serving = false;
              if (restartsAfterDeath) {
                // What the menu-bar app or `brew services` does.
                Future<void>.delayed(
                  const Duration(milliseconds: 60),
                  () => serving = true,
                );
              }
            }
          }
          return ProcessResult(0, 0, '', '');
        },
        shutdownTimeout: const Duration(milliseconds: 400),
        pollInterval: const Duration(milliseconds: 25),
        restartGrace: const Duration(milliseconds: 200),
      );
      return (launcher: l, commands: commands);
    }

    test('SIGTERM is enough for a well-behaved server', () async {
      final s = stoppable(diesOnTerm: true);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(s.commands.where((c) => c[0].endsWith('kill')).single, <String>[
        '/bin/kill',
        '-TERM',
        '9001',
      ]);
      // No escalation when TERM worked.
      expect(s.commands.any((c) => c.contains('-KILL')), isFalse);
    });

    test('escalates to SIGKILL when SIGTERM is ignored', () async {
      final s = stoppable(diesOnTerm: false);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      final signals = s.commands
          .where((c) => c[0].endsWith('kill'))
          .map((c) => c[1])
          .toList();
      expect(signals, <String>['-TERM', '-KILL']);
    });

    test('stopping something already stopped is not an error', () async {
      final l = launcher(up: () => false);

      expect(await l.stop(), StopOutcome.notRunning);
      expect(l.explainStop(StopOutcome.notRunning), isEmpty);
    });

    test('serving but unfindable is reported, not silently ignored', () async {
      // Nothing to signal: no pid from us, and pgrep finds none.
      final commands = <List<String>>[];
      final l = OllamaLauncher(
        clientThatIsUp(() => true),
        searchPaths: <String>[Platform.resolvedExecutable],
        spawn: (_) async => 4242,
        run: (exe, args) async {
          commands.add(<String>[exe, ...args]);
          return ProcessResult(0, 1, '', '');
        },
        shutdownTimeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 25),
      );

      expect(await l.stop(), StopOutcome.notFound);
      expect(l.explainStop(StopOutcome.notFound), contains('11434'));
      expect(commands.any((c) => c[0].endsWith('kill')), isFalse);
    });

    test('kills a server it did not start', () async {
      // The user started `ollama serve` in a terminal; Stop must still work,
      // so the pid has to come from pgrep rather than from our own spawn.
      final s = stoppable(diesOnTerm: true, pgrepPids: <int>[7777]);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(s.commands.where((c) => c[0].endsWith('kill')).single, <String>[
        '/bin/kill',
        '-TERM',
        '7777',
      ]);
    });

    test('signals the menu-bar app before its server', () async {
      // Ollama.app restarts a dead server, so it has to go first.
      final s = stoppable(diesOnTerm: true, appPids: <int>[500]);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(s.commands.where((c) => c[0].endsWith('kill')).toList(), [
        <String>['/bin/kill', '-TERM', '500'],
        <String>['/bin/kill', '-TERM', '9001'],
      ]);
    });

    test(
      'a server that comes back by itself is not reported as stopped',
      () async {
        final s = stoppable(diesOnTerm: true, restartsAfterDeath: true);

        expect(await s.launcher.stop(), StopOutcome.restarted);
        expect(
          s.launcher.explainStop(StopOutcome.restarted),
          contains('brew services stop ollama'),
        );
      },
    );

    test('a server that survives SIGKILL is reported as failed', () async {
      final l = OllamaLauncher(
        clientThatIsUp(() => true), // never stops answering
        searchPaths: <String>[Platform.resolvedExecutable],
        spawn: (_) async => 4242,
        run: (_, _) async => ProcessResult(0, 0, '9001', ''),
        shutdownTimeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 25),
      );

      expect(await l.stop(), StopOutcome.failed);
      expect(l.explainStop(StopOutcome.failed), contains('pkill -9'));
    });

    test('status messages describe both phases', () async {
      final s = stoppable(diesOnTerm: false);
      final status = <String>[];

      await s.launcher.stop(onStatus: status.add);

      expect(status.first, 'Stopping Ollama…');
      expect(status, contains('Not responding — forcing…'));
    });
  });

  test('default search paths cover installer and Homebrew locations', () {
    final paths = OllamaLauncher.defaultSearchPaths();
    expect(paths, contains('/usr/local/bin/ollama'));
    expect(paths, contains('/opt/homebrew/bin/ollama'));
    // A GUI app gets a minimal PATH, so these must be explicit, not searched.
    expect(paths.every((p) => p.startsWith('/')), isTrue);
  });
}
