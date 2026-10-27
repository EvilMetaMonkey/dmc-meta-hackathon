import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dmc/dmc.dart';
import 'package:dmc/src/workspace_operation_lock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const museSession = '22222222-3333-4444-8555-666666666666';
const claudeSession = '11111111-2222-4333-8444-555555555555';
const museTurn = '33333333-4444-7555-8666-777777777777';

/// The package root, resolved from `package:dmc` rather than the process cwd:
/// `dart test` runs files in parallel isolates of one process, and other test
/// files change `Directory.current`.
final String packageRoot = p.dirname(
  p.dirname(
    Isolate.resolvePackageUriSync(
      Uri.parse('package:dmc/dmc.dart'),
    )!.toFilePath(),
  ),
);

/// A fixture payload with `cwd` (and optionally other fields) replaced.
String fixture(
  String agentDirectory,
  String name, {
  required String cwd,
  Map<String, Object?> overrides = const {},
}) {
  final file = File(
    p.join(
      packageRoot,
      'test',
      'fixtures',
      'agent_hooks',
      agentDirectory,
      '$name.json',
    ),
  );
  final payload = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  return jsonEncode({...payload, 'cwd': cwd, ...overrides});
}

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;
  late DmcPaths paths;
  late List<String> warnings;
  late Map<String, String> environment;
  late String processCwd;
  var servicesCreated = 0;

  AgentHookRunner runner({
    Duration lockBudget = const Duration(seconds: 2),
    Duration lockRetryDelay = const Duration(milliseconds: 20),
  }) => AgentHookRunner(
    environment: environment,
    currentDirectory: () => processCwd,
    serviceFactory: (rootPath) {
      servicesCreated++;
      return CheckpointService(basePath: rootPath, homePath: home.path);
    },
    warn: warnings.add,
    lockBudget: lockBudget,
    lockRetryDelay: lockRetryDelay,
  );

  Future<void> hook(
    String agent,
    String event, {
    String? stdinText,
    AgentHookRunner? using,
  }) => (using ?? runner()).run([agent, event], stdinText: stdinText);

  List<CheckpointRecord> checkpoints() {
    final database = DmcDatabase(paths.dbPath)..initialize();
    try {
      return CheckpointRepository(database).listCheckpoints().reversed.toList();
    } finally {
      database.close();
    }
  }

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('dmc_agent_hooks_');
    root = Directory(p.join(sandbox.path, 'project'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    File(p.join(root.path, 'auth.dart')).writeAsStringSync('v1');
    warnings = [];
    environment = {'HOME': home.path};
    processCwd = root.path;
    servicesCreated = 0;
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('Muse Code turn begins on prompt and closes on Stop', () async {
    final transcript = File(
      p.join(
        home.path,
        '.local',
        'share',
        'muse',
        'sessions',
        '2026',
        '10',
        '26',
        museSession,
        'session.jsonl',
      ),
    )..createSync(recursive: true);
    transcript.writeAsStringSync('{"sequence":1}\n');

    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    var records = checkpoints();
    expect(records, hasLength(1));
    expect(records.single.status, CheckpointStatus.open);
    expect(records.single.source, 'muse-code');
    expect(records.single.label, 'reply with the word ok');
    expect(records.single.agent!.sessionId, museSession);
    expect(records.single.agent!.turnId, museTurn);
    expect(records.single.agent!.transcriptPath, transcript.path);
    expect(records.single.agent!.transcriptBytes, isNull);

    File(p.join(root.path, 'auth.dart')).writeAsStringSync('v2');
    transcript.writeAsStringSync('{"sequence":2}\n', mode: FileMode.append);
    await hook(
      'muse-code',
      'Stop',
      stdinText: fixture('muse_code', 'stop', cwd: root.path),
    );
    records = checkpoints();
    expect(records.single.status, CheckpointStatus.closed);
    final bytes = transcript.readAsBytesSync();
    expect(records.single.agent!.transcriptBytes, bytes.length);
    expect(
      records.single.agent!.transcriptSha256,
      sha256.convert(bytes).toString(),
    );
    final view = await CheckpointService(
      basePath: root.path,
      homePath: home.path,
    ).show(records.single.id);
    expect(view.data['files'], [containsPair('change', 'modified')]);
    final agentJson =
        (view.data['checkpoint'] as Map<String, Object?>)['agent'] as Map;
    expect(agentJson['name'], 'muse-code');
    expect(agentJson['transcriptBytes'], bytes.length);
    expect(
      checkpointHumanLines(view),
      contains(startsWith('Agent: muse-code')),
    );
    expect(warnings, isEmpty);

    // SessionEnd after Stop finds nothing to close.
    await hook(
      'muse-code',
      'SessionEnd',
      stdinText: fixture('muse_code', 'session_end', cwd: root.path),
    );
    expect(checkpoints(), hasLength(1));
    expect(warnings, isEmpty);
  });

  test(
    'Claude Code turn records prompt_id and the payload transcript',
    () async {
      final transcript = File(p.join(home.path, 'claude.jsonl'))
        ..writeAsStringSync('line\n');
      final overrides = {'transcript_path': transcript.path};
      await hook(
        'claude-code',
        'SessionStart',
        stdinText: fixture(
          'claude_code',
          'session_start',
          cwd: root.path,
          overrides: overrides,
        ),
      );
      expect(checkpoints(), isEmpty);
      await hook(
        'claude-code',
        'UserPromptSubmit',
        stdinText: fixture(
          'claude_code',
          'user_prompt_submit',
          cwd: root.path,
          overrides: overrides,
        ),
      );
      final open = checkpoints().single;
      expect(open.label, 'reply ok');
      expect(open.agent!.agent, 'claude-code');
      expect(open.agent!.sessionId, claudeSession);
      expect(open.agent!.turnId, '66666666-7777-4888-8999-aaaaaaaaaaaa');

      await hook(
        'claude-code',
        'StopFailure',
        stdinText: fixture(
          'claude_code',
          'stop_failure',
          cwd: root.path,
          overrides: overrides,
        ),
      );
      final closed = checkpoints().single;
      expect(closed.status, CheckpointStatus.closed);
      expect(closed.agent!.transcriptBytes, 5);
      expect(warnings, isEmpty);
    },
  );

  test('a missing transcript records no size or hash', () async {
    await hook(
      'claude-code',
      'UserPromptSubmit',
      stdinText: fixture('claude_code', 'user_prompt_submit', cwd: root.path),
    );
    await hook(
      'claude-code',
      'Stop',
      stdinText: fixture('claude_code', 'stop', cwd: root.path),
    );
    final closed = checkpoints().single;
    expect(closed.status, CheckpointStatus.closed);
    expect(closed.agent!.transcriptPath, endsWith('$claudeSession.jsonl'));
    expect(closed.agent!.transcriptBytes, isNull);
    expect(closed.agent!.transcriptSha256, isNull);
  });

  test('a missed Stop is closed by the next prompt in the session', () async {
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture(
        'muse_code',
        'user_prompt_submit',
        cwd: root.path,
        overrides: {'prompt': 'Second turn', 'turn_id': 'turn-0002'},
      ),
    );
    final records = checkpoints();
    expect(records.map((record) => record.status), [
      CheckpointStatus.closed,
      CheckpointStatus.open,
    ]);
    expect(records.last.label, 'Second turn');
    expect(records.last.agent!.turnId, 'turn-0002');
    expect(warnings.single, contains('left open by an earlier Muse Code turn'));
  });

  test('Interrupt closes a Muse turn but is ignored for Claude Code', () async {
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    await hook(
      'claude-code',
      'Interrupt',
      stdinText: fixture('muse_code', 'interrupt', cwd: root.path),
    );
    expect(checkpoints().single.status, CheckpointStatus.open);
    await hook(
      'muse-code',
      'Interrupt',
      stdinText: fixture('muse_code', 'interrupt', cwd: root.path),
    );
    expect(checkpoints().single.status, CheckpointStatus.closed);
  });

  test('a late async Interrupt does not close the next turn', () async {
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture(
        'muse_code',
        'user_prompt_submit',
        cwd: root.path,
        overrides: {'prompt': 'Second turn', 'turn_id': 'turn-0002'},
      ),
    );
    await hook(
      'muse-code',
      'Interrupt',
      stdinText: fixture('muse_code', 'interrupt', cwd: root.path),
    );
    expect(checkpoints().last.status, CheckpointStatus.open);
    await hook(
      'muse-code',
      'Stop',
      stdinText: fixture(
        'muse_code',
        'stop',
        cwd: root.path,
        overrides: {'turn_id': 'turn-0002'},
      ),
    );
    expect(checkpoints().last.status, CheckpointStatus.closed);
    expect(warnings, hasLength(1));
  });

  test('a foreign active checkpoint is left alone', () async {
    final service = CheckpointService(basePath: root.path, homePath: home.path);
    final manual = await service.begin(label: 'manual', source: 'haven');
    expect(manual.exitCode, 0, reason: manual.encode());

    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    await hook(
      'muse-code',
      'Stop',
      stdinText: fixture('muse_code', 'stop', cwd: root.path),
    );
    final records = checkpoints();
    expect(records, hasLength(1));
    expect(records.single.source, 'haven');
    expect(records.single.status, CheckpointStatus.open);
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('source haven'));
    expect(warnings.single, contains('No checkpoint was started'));
  });

  test('another session of the same agent is foreign', () async {
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    final other = {'session_id': 'other-session'};
    await hook(
      'muse-code',
      'Stop',
      stdinText: fixture('muse_code', 'stop', cwd: root.path, overrides: other),
    );
    expect(checkpoints().single.status, CheckpointStatus.open);
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture(
        'muse_code',
        'user_prompt_submit',
        cwd: root.path,
        overrides: other,
      ),
    );
    expect(checkpoints(), hasLength(1));
    expect(warnings.single, contains('belongs to another owner'));
  });

  test('no workspace is a silent no-op', () async {
    final outside = Directory(p.join(sandbox.path, 'elsewhere'))..createSync();
    processCwd = outside.path;
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: outside.path),
    );
    await hook('claude-code', 'Stop', stdinText: '');
    expect(servicesCreated, 0);
    expect(warnings, isEmpty);
    expect(checkpoints(), isEmpty);
  });

  test('empty or invalid stdin falls back to MUSE_SESSION_ID', () async {
    environment['MUSE_SESSION_ID'] = museSession;
    await hook('muse-code', 'UserPromptSubmit', stdinText: '');
    var record = checkpoints().single;
    expect(record.status, CheckpointStatus.open);
    expect(record.label, 'Muse Code turn');
    expect(record.agent!.sessionId, museSession);
    expect(record.agent!.turnId, isNull);

    // A full payload from the same session can close it.
    await hook('muse-code', 'Stop', stdinText: '{not json');
    record = checkpoints().single;
    expect(record.status, CheckpointStatus.closed);
    expect(warnings, isEmpty);
  });

  test('a subdirectory cwd finds the enclosing workspace', () async {
    final nested = Directory(p.join(root.path, 'lib', 'src'))
      ..createSync(recursive: true);
    processCwd = sandbox.path;
    await hook(
      'claude-code',
      'UserPromptSubmit',
      stdinText: fixture('claude_code', 'user_prompt_submit', cwd: nested.path),
    );
    expect(checkpoints().single.status, CheckpointStatus.open);
    await hook(
      'claude-code',
      'Stop',
      stdinText: fixture('claude_code', 'stop', cwd: nested.path),
    );
    expect(checkpoints().single.status, CheckpointStatus.closed);
  });

  test('a busy workspace lock is retried, then given up on', () async {
    var lock = WorkspaceOperationLock.acquire(paths);
    try {
      await hook(
        'muse-code',
        'UserPromptSubmit',
        stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
        using: runner(lockBudget: const Duration(milliseconds: 150)),
      );
    } finally {
      lock.close();
    }
    expect(checkpoints(), isEmpty);
    expect(warnings.single, contains('Another checkpoint command is running'));

    warnings.clear();
    lock = WorkspaceOperationLock.acquire(paths);
    final released = Future<void>.delayed(
      const Duration(milliseconds: 150),
      lock.close,
    );
    await hook(
      'muse-code',
      'UserPromptSubmit',
      stdinText: fixture('muse_code', 'user_prompt_submit', cwd: root.path),
    );
    await released;
    expect(checkpoints().single.status, CheckpointStatus.open);
    expect(warnings, isEmpty);
  });

  test('bad arguments warn and never throw', () async {
    await runner().run(['codex', 'Stop']);
    await runner().run(['muse-code']);
    expect(warnings, hasLength(2));
    expect(checkpoints(), isEmpty);
  });

  test('the command exits 0 and prints nothing even when it fails', () async {
    final printed = <String>[];
    final code = await runZoned(
      () => runAgentHookCommand([
        'muse-code',
        'UserPromptSubmit',
      ], readStdin: () async => throw StateError('stdin exploded')),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => printed.add(message),
      ),
    );
    expect(code, 0);
    expect(printed, isEmpty);

    final viaCli = await runZoned(
      () => runAgentHookCommand(
        ['muse-code', 'UserPromptSubmit'],
        readStdin: () async =>
            fixture('muse_code', 'user_prompt_submit', cwd: root.path),
        runner: runner(),
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => printed.add(message),
      ),
    );
    expect(viaCli, 0);
    expect(printed, isEmpty);
    expect(checkpoints().single.status, CheckpointStatus.open);
  });

  test('labels use the first line, trimmed to 100 characters', () {
    expect(
      agentTurnLabel(HookAgent.museCode, '  Fix the bug  \nmore detail'),
      'Fix the bug',
    );
    expect(agentTurnLabel(HookAgent.claudeCode, '\n'), 'Claude Code turn');
    final long = agentTurnLabel(HookAgent.museCode, 'é' * 150);
    expect(long.runes.length, 100);
    expect(long, endsWith('…'));
  });

  test('Muse transcript lookup rejects unsafe session IDs', () {
    expect(findMuseTranscript('../escape', {'HOME': home.path}), isNull);
    expect(findMuseTranscript(museSession, {'HOME': home.path}), isNull);
  });
}
