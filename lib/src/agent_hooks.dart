import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'checkpoint_models.dart';
import 'checkpoint_service.dart';
import 'machine_output.dart';
import 'workspace.dart';

/// A coding agent whose turn hooks call `dmc agent-hook`.
enum HookAgent {
  museCode('muse-code', 'Muse Code', ['MUSE_SESSION_ID', 'MUSE_THREAD_ID']),
  claudeCode('claude-code', 'Claude Code', ['CLAUDE_CODE_SESSION_ID']);

  /// The CLI name, also used as the checkpoint source.
  final String id;
  final String displayName;

  /// Environment variables that carry the session ID, in preference order.
  final List<String> sessionEnvironment;

  const HookAgent(this.id, this.displayName, this.sessionEnvironment);

  static HookAgent? fromId(String value) {
    for (final agent in values) {
      if (agent.id == value) return agent;
    }
    return null;
  }

  /// Hook events that end a turn for this agent. Claude Code has no
  /// Interrupt event; a cancelled turn is closed by the next prompt instead.
  Set<String> get closeEvents => switch (this) {
    museCode => const {'Stop', 'StopFailure', 'Interrupt', 'SessionEnd'},
    claudeCode => const {'Stop', 'StopFailure', 'SessionEnd'},
  };
}

enum AgentHookAction { begin, close, none }

AgentHookAction agentHookAction(HookAgent agent, String event) {
  if (event == 'UserPromptSubmit') return AgentHookAction.begin;
  if (agent.closeEvents.contains(event)) return AgentHookAction.close;
  return AgentHookAction.none;
}

const int _maxLabelLength = 100;

/// The checkpoint label for a prompt: its first line, trimmed, at most
/// [_maxLabelLength] characters.
String agentTurnLabel(HookAgent agent, String? prompt) {
  final firstLine = (prompt ?? '').split(RegExp(r'\r?\n')).first.trim();
  if (firstLine.isEmpty) return '${agent.displayName} turn';
  final runes = firstLine.runes.toList();
  if (runes.length <= _maxLabelLength) return firstLine;
  return '${String.fromCharCodes(runes.take(_maxLabelLength - 1)).trimRight()}…';
}

/// The fields dmc reads from an agent hook's stdin payload.
class AgentHookPayload {
  final String? sessionId;
  final String? turnId;
  final String? cwd;
  final String? transcriptPath;
  final String? prompt;

  const AgentHookPayload({
    this.sessionId,
    this.turnId,
    this.cwd,
    this.transcriptPath,
    this.prompt,
  });

  /// Parse [stdinText], falling back to [environment] for the session ID
  /// when stdin is empty, invalid, or lacks one.
  factory AgentHookPayload.parse(
    HookAgent agent,
    String? stdinText,
    Map<String, String> environment,
  ) {
    Map<String, Object?> json = const {};
    if (stdinText != null && stdinText.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(stdinText);
        if (decoded is Map<String, Object?>) json = decoded;
      } on FormatException {
        // Fall back to the environment below.
      }
    }
    String? text(String key) {
      final value = json[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    String? environmentSession() {
      for (final name in agent.sessionEnvironment) {
        final value = environment[name];
        if (value != null && value.trim().isNotEmpty) return value.trim();
      }
      return null;
    }

    return AgentHookPayload(
      sessionId: text('session_id') ?? environmentSession(),
      // Muse Code sends turn_id; Claude Code identifies the turn by prompt_id.
      turnId: text('turn_id') ?? text('prompt_id'),
      cwd: text('cwd'),
      transcriptPath: text('transcript_path'),
      prompt: json['prompt'] is String ? json['prompt'] as String : null,
    );
  }
}

/// Walk up from [start] to the nearest directory that contains `.dmc/`.
String? findDmcWorkspace(String start) {
  var current = p.normalize(p.absolute(start));
  while (true) {
    final type = FileSystemEntity.typeSync(
      p.join(current, dmcDirName),
      followLinks: false,
    );
    if (type == FileSystemEntityType.directory) return current;
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

final _safeSessionId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');

/// Locate Muse Code's `session.jsonl` for [sessionId] under
/// `<data>/muse/sessions/YYYY/MM/DD/<session-id>/`, newest day first.
String? findMuseTranscript(String sessionId, Map<String, String> environment) {
  if (!_safeSessionId.hasMatch(sessionId)) return null;
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  final dataHome =
      environment['XDG_DATA_HOME'] ??
      (home == null ? null : p.join(home, '.local', 'share'));
  if (dataHome == null) return null;
  final sessions = Directory(p.join(dataHome, 'muse', 'sessions'));
  List<Directory> children(Directory directory) {
    try {
      return directory
          .listSync(followLinks: false)
          .whereType<Directory>()
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
    } on FileSystemException {
      return const [];
    }
  }

  for (final year in children(sessions)) {
    for (final month in children(year)) {
      for (final day in children(month)) {
        final candidate = p.join(day.path, sessionId, 'session.jsonl');
        if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
          return candidate;
        }
      }
    }
  }
  return null;
}

/// Turns agent hook events into checkpoint begin/close calls.
///
/// A hook must never block or alter an agent turn, so [run] never throws and
/// reports problems only through [warn].
class AgentHookRunner {
  final Map<String, String> environment;
  final String Function() currentDirectory;
  final CheckpointService Function(String rootPath) serviceFactory;
  final void Function(String message) warn;

  /// How long to keep retrying a busy workspace lock.
  final Duration lockBudget;
  final Duration lockRetryDelay;

  AgentHookRunner({
    Map<String, String>? environment,
    String Function()? currentDirectory,
    CheckpointService Function(String rootPath)? serviceFactory,
    void Function(String message)? warn,
    this.lockBudget = const Duration(seconds: 5),
    this.lockRetryDelay = const Duration(milliseconds: 100),
  }) : environment = environment ?? Platform.environment,
       currentDirectory = currentDirectory ?? (() => Directory.current.path),
       serviceFactory =
           serviceFactory ??
           ((rootPath) => CheckpointService(basePath: rootPath)),
       warn = warn ?? ((message) => stderr.writeln(message));

  Future<void> run(List<String> args, {String? stdinText}) async {
    try {
      await _run(args, stdinText);
    } catch (error) {
      _warn('unexpected error: $error');
    }
  }

  void _warn(String message) => warn('[DMC] agent-hook: $message');

  Future<void> _run(List<String> args, String? stdinText) async {
    if (args.length < 2) {
      _warn('usage: dmc agent-hook <muse-code|claude-code> <event>');
      return;
    }
    final agent = HookAgent.fromId(args[0]);
    if (agent == null) {
      _warn('unknown agent "${args[0]}"; expected muse-code or claude-code.');
      return;
    }
    final event = args[1];
    final action = agentHookAction(agent, event);
    if (action == AgentHookAction.none) return;

    final payload = AgentHookPayload.parse(agent, stdinText, environment);
    final start = payload.cwd != null && p.isAbsolute(payload.cwd!)
        ? payload.cwd!
        : currentDirectory();
    final root = findDmcWorkspace(start);
    if (root == null) return;

    final service = serviceFactory(root);
    var transcriptPath = payload.transcriptPath;
    if (transcriptPath == null &&
        agent == HookAgent.museCode &&
        payload.sessionId != null) {
      transcriptPath = findMuseTranscript(payload.sessionId!, environment);
    }
    bool owns(CheckpointRecord checkpoint) =>
        checkpoint.agent?.agent == agent.id &&
        checkpoint.agent?.sessionId == payload.sessionId;

    final closed = await _withLockRetry(
      () => service.closeActive(owns: owns, transcriptPath: transcriptPath),
    );
    final closeCode = _errorCode(closed);
    if (action == AgentHookAction.close) {
      if (closed.exitCode != 0 &&
          closeCode != 'no_active_checkpoint' &&
          closeCode != 'checkpoint_not_owned') {
        _warn('$event: could not close the checkpoint: ${_errorText(closed)}');
      }
      return;
    }

    // UserPromptSubmit. An open checkpoint from this session means its Stop
    // never arrived (for example, a cancelled turn): it was closed above.
    switch (closeCode) {
      case 'checkpoint_not_owned':
        _warn(
          '${_errorText(closed)} No checkpoint was started for this ${agent.displayName} turn.',
        );
        return;
      case 'checkpoint_busy':
      case 'checkpoint_not_open':
      case 'close_failed':
      case 'not_initialized':
        _warn('no checkpoint was started for this turn: ${_errorText(closed)}');
        return;
    }
    if (closed.ok) {
      _warn(
        'closed checkpoint ${_checkpointId(closed)}, left open by an earlier ${agent.displayName} turn in this session.',
      );
    } else if (closeCode != 'no_active_checkpoint') {
      _warn(
        'the earlier turn\'s checkpoint ${_checkpointId(closed) ?? ''} closed with errors: ${_errorText(closed)}',
      );
    }

    final began = await _withLockRetry(
      () => service.begin(
        label: agentTurnLabel(agent, payload.prompt),
        source: agent.id,
        agent: CheckpointAgentContext(
          agent: agent.id,
          sessionId: payload.sessionId,
          turnId: payload.turnId,
          transcriptPath: transcriptPath,
        ),
      ),
    );
    if (!began.ok) {
      _warn('could not begin a checkpoint: ${_errorText(began)}');
    }
  }

  Future<CommandResult> _withLockRetry(
    Future<CommandResult> Function() operation,
  ) async {
    final stopwatch = Stopwatch()..start();
    while (true) {
      final result = await operation();
      if (_errorCode(result) != 'checkpoint_busy' ||
          stopwatch.elapsed + lockRetryDelay > lockBudget) {
        return result;
      }
      await Future<void>.delayed(lockRetryDelay);
    }
  }

  static String? _errorCode(CommandResult result) =>
      result.errors.isEmpty ? null : result.errors.first.code;

  static String _errorText(CommandResult result) => result.errors.isEmpty
      ? 'exit ${result.exitCode}'
      : result.errors.map((error) => error.message).join(' ');

  static String? _checkpointId(CommandResult result) {
    final checkpoint = result.data['checkpoint'];
    return checkpoint is Map ? checkpoint['id'] as String? : null;
  }
}

/// Read a hook payload from stdin without waiting on a terminal or on a
/// pipe that never closes.
Future<String?> readHookStdin({
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    if (stdin.hasTerminal) return null;
    // A stream timeout errors the fold, which cancels the stdin subscription;
    // a Future timeout would leave it listening and keep the process alive.
    final bytes = await stdin
        .timeout(timeout)
        .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    return utf8.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// `dmc agent-hook <agent> <event>`. Always returns 0 and never writes to
/// stdout, so it can never block or alter an agent turn.
Future<int> runAgentHookCommand(
  List<String> args, {
  Future<String?> Function()? readStdin,
  AgentHookRunner? runner,
}) async {
  try {
    await runZoned(() async {
      final stdinText = await (readStdin ?? readHookStdin)();
      await (runner ?? AgentHookRunner()).run(args, stdinText: stdinText);
    }, zoneSpecification: ZoneSpecification(print: (_, _, _, _) {}));
  } catch (_) {
    // A hook failure must not reach the agent.
  }
  return 0;
}
