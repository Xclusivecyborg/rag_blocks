import 'dart:async';
import 'dart:io';

import 'ollama_client.dart';

/// Starts `ollama serve` detached and returns its pid.
typedef OllamaSpawn = Future<int?> Function(String executable);

/// Runs a short command (`pgrep`, `kill`) and waits for it.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

enum StopOutcome {
  stopped, // no longer answering
  notRunning, // was not running to begin with
  notFound, // something answers, but no `ollama serve` process to signal
  failed, // still answering even after SIGKILL
  restarted, // went down, then something (brew services, launchd) restarted it
}

enum LaunchOutcome {
  alreadyRunning,
  started, // we ran `ollama serve` and it answered in time
  notInstalled, // no `ollama` binary in any known location
  launchFailed, // the binary exists but would not start
  timedOut, // started, but never answered at the client's base URL
  unreachable; // nothing answers, and the base URL is not this machine

  bool get isUp => this == alreadyRunning || this == started;
}

/// Starts and stops the Ollama server, like running `ollama serve` in a
/// terminal. Most code only needs [OllamaClient.connect], which uses this.
///
/// It runs a process, so a sandboxed macOS app needs the App Sandbox off
/// (`com.apple.security.app-sandbox` set to false in the entitlements).
///
/// Starting and stopping work on macOS and Linux; on Windows, start Ollama
/// yourself and use [OllamaClient] directly.
///
/// The server is started fully detached, so it keeps running after the app
/// quits. `detachedWithStdio` is not enough: its pipes close with the app and
/// Ollama dies a few seconds later.
class OllamaLauncher {
  OllamaLauncher(
    this._client, {
    this.startupTimeout = const Duration(seconds: 30),
    this.shutdownTimeout = const Duration(seconds: 8),
    this.pollInterval = const Duration(milliseconds: 400),
    this.restartGrace = const Duration(seconds: 3),
    List<String>? searchPaths,
    OllamaSpawn? spawn,
    ProcessRunner? run,
  }) : _searchPaths = searchPaths ?? defaultSearchPaths(),
       _spawn = spawn ?? ((exe) => _startDetached(exe, _client.baseUrl)),
       _run = run ?? Process.run;

  final OllamaClient _client;
  final List<String> _searchPaths;
  final OllamaSpawn _spawn;
  final ProcessRunner _run;

  final Duration startupTimeout;
  final Duration shutdownTimeout; // wait after SIGTERM before SIGKILL
  final Duration pollInterval;

  /// How long the server must stay down after stopping. The Ollama menu-bar
  /// app restarts its server about 1.5s after it dies, and `brew services`
  /// does the same, so a quiet port alone does not mean it stopped.
  final Duration restartGrace;

  int? _spawnedPid; // the server we started, if any
  String? _lastSpawnError;

  /// Path of the `ollama` binary, once [resolve] has run.
  String? resolvedPath;

  /// Where to look for `ollama`. A macOS GUI app does not get the shell's
  /// PATH, so the usual install locations are listed explicitly.
  static List<String> defaultSearchPaths() {
    final home = Platform.environment['HOME'] ?? '';
    return [
      '/usr/local/bin/ollama', // ollama.com installer
      '/opt/homebrew/bin/ollama', // Homebrew, Apple silicon
      '/usr/local/opt/ollama/bin/ollama', // Homebrew, Intel
      if (home.isNotEmpty) '$home/.local/bin/ollama',
      '/usr/bin/ollama',
      '/Applications/Ollama.app/Contents/Resources/ollama',
    ];
  }

  /// The first search path that exists (following symlinks), or null.
  String? resolve() {
    for (final path in _searchPaths) {
      if (File(path).existsSync()) return resolvedPath = path;
    }
    return resolvedPath = null;
  }

  Future<bool> _isAnswering() async => await _client.version() != null;

  /// Makes sure the server is answering, starting it if needed.
  ///
  /// A server is only started when the client's base URL is on this machine
  /// (localhost or a loopback address). For any other host this returns
  /// [LaunchOutcome.unreachable] instead of starting an unrelated local one.
  Future<LaunchOutcome> ensureRunning({
    void Function(String message)? onStatus,
  }) async {
    if (await _isAnswering()) return LaunchOutcome.alreadyRunning;
    if (!isLoopback(_client.baseUrl)) return LaunchOutcome.unreachable;

    final binary = resolve();
    if (binary == null) return LaunchOutcome.notInstalled;

    _lastSpawnError = null;
    onStatus?.call('Starting ollama serve…');
    try {
      _spawnedPid = await _spawn(binary);
    } on Object catch (e) {
      _lastSpawnError = '$e';
      return LaunchOutcome.launchFailed;
    }

    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (await _isAnswering()) return LaunchOutcome.started;
      final secondsLeft = deadline.difference(DateTime.now()).inSeconds;
      if (secondsLeft > 0) {
        onStatus?.call('Waiting for Ollama… ${secondsLeft}s');
      }
    }
    return LaunchOutcome.timedOut;
  }

  /// Stops the server with SIGTERM, then SIGKILL if it does not respond.
  /// Ollama has no shutdown endpoint, so this is what `pkill ollama` does.
  ///
  /// On macOS the Ollama menu-bar app is signalled too, since it restarts
  /// any server that dies.
  Future<StopOutcome> stop({void Function(String message)? onStatus}) async {
    if (!await _isAnswering()) {
      _spawnedPid = null;
      return StopOutcome.notRunning;
    }

    final pids = await _serverPids();
    if (pids.isEmpty) return StopOutcome.notFound;

    for (final (signal, message) in [
      ('TERM', 'Stopping Ollama…'),
      ('KILL', 'Not responding — forcing…'),
    ]) {
      onStatus?.call(message);
      await _signal(pids, signal);
      if (await _waitUntilDown()) {
        _spawnedPid = null;
        return await _staysDown() ? StopOutcome.stopped : StopOutcome.restarted;
      }
    }
    return StopOutcome.failed;
  }

  /// The menu-bar app first, so it cannot restart the server, then the
  /// server we started, then any other `ollama serve` the user started.
  Future<List<int>> _serverPids() async => {
    ...await _pgrep(menuBarAppPattern),
    ?_spawnedPid,
    ...await _pgrep('ollama serve'),
  }.toList();

  /// Matches the Ollama.app process that supervises its own server.
  static const String menuBarAppPattern = 'Ollama.app/Contents/MacOS/Ollama';

  Future<List<int>> _pgrep(String pattern) async {
    try {
      final result = await _run('/usr/bin/pgrep', ['-f', pattern]);
      return [
        for (final line in '${result.stdout}'.split('\n'))
          if (int.tryParse(line.trim()) case final found?)
            if (found != pid) found, // never ourselves
      ];
    } on Object {
      return const []; // no pgrep; _spawnedPid may still be enough
    }
  }

  /// True if the server is still down after [restartGrace].
  Future<bool> _staysDown() async {
    final deadline = DateTime.now().add(restartGrace);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (await _isAnswering()) return false;
    }
    return true;
  }

  Future<void> _signal(List<int> pids, String signal) async {
    for (final target in pids) {
      try {
        await _run('/bin/kill', ['-$signal', '$target']);
      } on Object {
        // Already gone or not ours; _waitUntilDown decides.
      }
    }
  }

  /// Waits for the port to go quiet, which is the only reliable sign that
  /// the server stopped.
  Future<bool> _waitUntilDown() async {
    final deadline = DateTime.now().add(shutdownTimeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      if (!await _isAnswering()) return true;
    }
    return false;
  }

  /// An error message for [outcome], or '' if it succeeded.
  String explainStop(StopOutcome outcome) => switch (outcome) {
    StopOutcome.stopped || StopOutcome.notRunning => '',
    StopOutcome.notFound =>
      'Something is answering at ${_client.baseUrl}, but no "ollama serve" '
          'process '
          'was found to stop. It may be running under another user or in a '
          'container.',
    StopOutcome.failed =>
      'Ollama did not stop, even after SIGKILL. Try "pkill -9 ollama" in a '
          'terminal.',
    StopOutcome.restarted =>
      'Ollama stopped, then something started it again. If you installed it '
          'with Homebrew, run "brew services stop ollama"; otherwise quit it '
          'from its menu-bar icon.',
  };

  /// An error message for [outcome], or '' if Ollama is up. A detached
  /// server's own errors cannot be seen, so each message points to the
  /// terminal.
  String explainLaunch(LaunchOutcome outcome) {
    final detail = _lastSpawnError == null ? '' : '\n\n$_lastSpawnError';
    return switch (outcome) {
      LaunchOutcome.alreadyRunning || LaunchOutcome.started => '',
      LaunchOutcome.notInstalled =>
        'No "ollama" binary found.\n'
            'Install it from ollama.com or with: brew install ollama\n'
            'Then try again.',
      LaunchOutcome.launchFailed =>
        'Found $resolvedPath but it would not '
            'start.\nRun "ollama serve" in a terminal, then try again.$detail',
      LaunchOutcome.timedOut =>
        'Started $resolvedPath but nothing answered at ${_client.baseUrl} '
            'within '
            '${startupTimeout.inSeconds}s.\n'
            'Run "ollama serve" in a terminal to see what it says.',
      LaunchOutcome.unreachable =>
        'Nothing answered at ${_client.baseUrl}. It is not on this machine, '
            'so it was not started here. Check that Ollama is running there '
            'and listening on that address.',
    };
  }

  /// Whether [url] points at this machine.
  static bool isLoopback(Uri url) =>
      url.host == 'localhost' ||
      (InternetAddress.tryParse(url.host)?.isLoopback ?? false);

  /// Starts `ollama serve` listening on [baseUrl]'s host and port, which
  /// `ollama serve` reads from `OLLAMA_HOST`.
  static Future<int?> _startDetached(String executable, Uri baseUrl) async {
    final host = baseUrl.host.contains(':')
        ? '[${baseUrl.host}]'
        : baseUrl.host;
    final process = await Process.start(
      executable,
      const ['serve'],
      mode: ProcessStartMode.detached,
      environment: {'OLLAMA_HOST': '$host:${baseUrl.port}'},
    );
    return process.pid;
  }
}
