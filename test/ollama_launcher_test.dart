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
    isWindows: false,
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
    expect(l.explainLaunch(outcome), contains('http://127.0.0.1:11434'));
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
        isWindows: false,
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
        isWindows: false,
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
        isWindows: false,
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
    final paths = OllamaLauncher.defaultSearchPaths(windows: false);
    expect(paths, contains('/usr/local/bin/ollama'));
    expect(paths, contains('/opt/homebrew/bin/ollama'));
    // A GUI app gets a minimal PATH, so these must be explicit, not searched.
    expect(paths.every((p) => p.startsWith('/')), isTrue);
  });

  group('Windows', () {
    test('default search paths are the installer and Program Files', () {
      final paths = OllamaLauncher.defaultSearchPaths(
        windows: true,
        environment: const {
          'LOCALAPPDATA': r'C:\Users\ada\AppData\Local',
          'ProgramFiles': r'C:\Program Files',
        },
      );
      expect(paths, <String>[
        r'C:\Users\ada\AppData\Local\Programs\Ollama\ollama.exe',
        r'C:\Program Files\Ollama\ollama.exe',
      ]);
    });

    test('unset folders are left out of the search paths', () {
      final paths = OllamaLauncher.defaultSearchPaths(
        windows: true,
        environment: const {},
      );
      expect(paths, isEmpty);
    });

    OllamaLauncher onPath(
      Future<ProcessResult> Function(String exe, List<String> args) run, {
      required void Function(String executable) onSpawn,
      bool isWindows = true,
    }) => OllamaLauncher(
      clientThatIsUp(() => false),
      searchPaths: <String>[r'C:\nowhere\ollama.exe'],
      spawn: (executable) async {
        onSpawn(executable);
        return 4242;
      },
      run: run,
      isWindows: isWindows,
      startupTimeout: const Duration(milliseconds: 100),
      pollInterval: const Duration(milliseconds: 20),
    );

    test('falls back to the ollama.exe that where finds on PATH', () async {
      String? spawned;
      final ran = <List<String>>[];
      final l = onPath((exe, args) async {
        ran.add(<String>[exe, ...args]);
        return ProcessResult(
          0,
          0,
          'C:\\tools\\ollama.exe\r\nC:\\other\\ollama.exe\r\n',
          '',
        );
      }, onSpawn: (exe) => spawned = exe);

      expect(await l.ensureRunning(), LaunchOutcome.timedOut);
      expect(ran, [
        <String>['where', 'ollama'],
      ]);
      expect(spawned, r'C:\tools\ollama.exe');
      expect(l.resolvedPath, r'C:\tools\ollama.exe');
    });

    test('where finding nothing is reported as not installed', () async {
      var spawned = false;
      final l = onPath(
        (_, _) async => ProcessResult(0, 1, '', 'INFO: Could not find files'),
        onSpawn: (_) => spawned = true,
      );

      expect(await l.ensureRunning(), LaunchOutcome.notInstalled);
      expect(spawned, isFalse);
    });

    test('PATH is not searched on macOS and Linux', () async {
      final ran = <List<String>>[];
      final l = onPath(
        (exe, args) async {
          ran.add(<String>[exe, ...args]);
          return ProcessResult(0, 0, '/usr/bin/ollama', '');
        },
        onSpawn: (_) {},
        isWindows: false,
      );

      expect(await l.ensureRunning(), LaunchOutcome.notInstalled);
      expect(ran, isEmpty);
    });
  });

  group('Windows stop', () {
    /// tasklist's CSV row for each pid, as `/FO CSV /NH` prints it.
    String rows(String image, List<int> pids) => pids.isEmpty
        ? 'INFO: No tasks are running which match the specified criteria.\r\n'
        : [
            for (final p in pids) '"$image","$p","Console","1","45,000 K"\r\n',
          ].join();

    ({OllamaLauncher launcher, List<List<String>> commands}) stoppable({
      required bool diesOnTerm,
      List<int> serverPids = const <int>[9001],
      List<int> trayPids = const <int>[],
    }) {
      final commands = <List<String>>[];
      var serving = true;

      final l = OllamaLauncher(
        clientThatIsUp(() => serving),
        searchPaths: <String>[Platform.resolvedExecutable],
        spawn: (_) async => 4242,
        isWindows: true,
        run: (exe, args) async {
          commands.add(<String>[exe, ...args]);
          if (exe == 'tasklist') {
            final tray = args[1] == 'IMAGENAME eq ollama app.exe';
            return ProcessResult(
              0,
              0,
              tray
                  ? rows('ollama app.exe', trayPids)
                  : rows('ollama.exe', serverPids),
              '',
            );
          }
          if (exe == 'taskkill' && (diesOnTerm || args.first == '/F')) {
            serving = false;
          }
          return ProcessResult(0, 0, '', '');
        },
        shutdownTimeout: const Duration(milliseconds: 400),
        pollInterval: const Duration(milliseconds: 25),
        restartGrace: const Duration(milliseconds: 200),
      );
      return (launcher: l, commands: commands);
    }

    List<List<String>> taskkills(List<List<String>> commands) =>
        commands.where((c) => c[0] == 'taskkill').toList();

    test('finds pids with tasklist and stops them with taskkill', () async {
      final s = stoppable(diesOnTerm: true, serverPids: <int>[9001, 9002]);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(
        s.commands.where((c) => c[0] == 'tasklist').map((c) => c.sublist(1)),
        [
          <String>['/FI', 'IMAGENAME eq ollama app.exe', '/FO', 'CSV', '/NH'],
          <String>['/FI', 'IMAGENAME eq ollama.exe', '/FO', 'CSV', '/NH'],
        ],
      );
      expect(taskkills(s.commands), [
        <String>['taskkill', '/PID', '9001'],
        <String>['taskkill', '/PID', '9002'],
      ]);
      // No Unix tools on Windows.
      expect(s.commands.any((c) => c[0].startsWith('/')), isFalse);
    });

    test('escalates to taskkill /F when the server ignores taskkill', () async {
      final s = stoppable(diesOnTerm: false);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(taskkills(s.commands), [
        <String>['taskkill', '/PID', '9001'],
        <String>['taskkill', '/F', '/PID', '9001'],
      ]);
    });

    test('forces at once when nothing accepts the polite taskkill', () async {
      // A console `ollama serve` has no window to close, so plain taskkill
      // fails; waiting out shutdownTimeout before /F would gain nothing.
      var serving = true;
      final commands = <List<String>>[];
      final l = OllamaLauncher(
        clientThatIsUp(() => serving),
        searchPaths: <String>[Platform.resolvedExecutable],
        spawn: (_) async => 4242,
        isWindows: true,
        run: (exe, args) async {
          commands.add(<String>[exe, ...args]);
          if (exe == 'tasklist') {
            return ProcessResult(0, 0, rows('ollama.exe', [9001]), '');
          }
          if (args.first != '/F') {
            return ProcessResult(0, 1, '', 'can only be terminated forcefully');
          }
          serving = false;
          return ProcessResult(0, 0, '', '');
        },
        shutdownTimeout: const Duration(seconds: 5),
        pollInterval: const Duration(milliseconds: 25),
        restartGrace: const Duration(milliseconds: 100),
      );

      final sw = Stopwatch()..start();
      expect(await l.stop(), StopOutcome.stopped);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      expect(taskkills(commands).last, <String>[
        'taskkill',
        '/F',
        '/PID',
        '9001',
      ]);
    });

    test('signals the tray app before its server', () async {
      // The tray app restarts a dead server, so it has to go first.
      final s = stoppable(diesOnTerm: true, trayPids: <int>[500]);

      expect(await s.launcher.stop(), StopOutcome.stopped);
      expect(taskkills(s.commands), [
        <String>['taskkill', '/PID', '500'],
        <String>['taskkill', '/PID', '9001'],
      ]);
    });

    test('no matching tasks and no spawned pid is reported as notFound', () {
      final s = stoppable(diesOnTerm: true, serverPids: const <int>[]);
      expect(s.launcher.stop(), completion(StopOutcome.notFound));
    });

    test('messages name the Windows commands', () {
      final l = stoppable(diesOnTerm: true).launcher;
      expect(l.explainStop(StopOutcome.failed), contains('taskkill /F'));
      expect(
        l.explainStop(StopOutcome.restarted),
        contains('notification area'),
      );
      expect(
        l.explainLaunch(LaunchOutcome.notInstalled),
        isNot(contains('brew')),
      );
    });
  });

  group('base URL', () {
    OllamaLauncher launcherAt(String url, {required void Function() onSpawn}) =>
        OllamaLauncher(
          OllamaClient(
            baseUrl: Uri.parse(url),
            client: MockClient((_) async => http.Response('down', 500)),
          ),
          searchPaths: [Platform.resolvedExecutable],
          spawn: (_) async {
            onSpawn();
            return 4242;
          },
          startupTimeout: const Duration(milliseconds: 100),
          pollInterval: const Duration(milliseconds: 20),
        );

    test('a remote server that is down is not started locally', () async {
      var spawned = false;
      final l = launcherAt(
        'http://gpu-box.lan:11434',
        onSpawn: () => spawned = true,
      );

      final outcome = await l.ensureRunning();

      expect(outcome, LaunchOutcome.unreachable);
      expect(outcome.isUp, isFalse);
      expect(spawned, isFalse);
      expect(l.explainLaunch(outcome), contains('gpu-box.lan'));
    });

    test('localhost and loopback addresses are started', () async {
      for (final url in [
        'http://localhost:11500',
        'http://127.0.0.1:11500',
        'http://[::1]:11500',
      ]) {
        var spawned = false;
        final l = launcherAt(url, onSpawn: () => spawned = true);
        expect(await l.ensureRunning(), LaunchOutcome.timedOut, reason: url);
        expect(spawned, isTrue, reason: url);
      }
    });

    test('messages name the configured address, not the default port', () {
      final l = launcherAt('http://127.0.0.1:11500', onSpawn: () {});
      expect(l.explainLaunch(LaunchOutcome.timedOut), contains(':11500'));
      expect(l.explainStop(StopOutcome.notFound), contains(':11500'));
    });

    test('connect() to a remote server that is down throws', () async {
      await expectLater(
        OllamaClient.connect(baseUrl: Uri.parse('http://192.0.2.1:9')),
        throwsA(
          isA<OllamaException>().having(
            (e) => e.message,
            'message',
            contains('not on this machine'),
          ),
        ),
      );
    });
  });
}
