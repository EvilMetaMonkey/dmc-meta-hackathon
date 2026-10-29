@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

/// Passes when state.txt says "good".
final String goodTest = Platform.isWindows
    ? 'findstr /c:good state.txt >nul'
    : 'grep -q good state.txt';

/// Distinct wording per approach, so plans are clearly different.
const List<String> _angles = [
  'Start from the configuration and keep the public interface unchanged.',
  'Work through the call sites one by one and add a regression check.',
  'Replace the helper entirely with a smaller standalone version.',
];

String plan(List<(String, String)> items) => jsonEncode({
  'approaches': [
    for (final (i, (title, marker)) in items.indexed)
      {
        'title': title,
        'plan':
            '${_angles[i % _angles.length]} ${switch (marker) {
              'FAKE-FIX' => 'FAKE-FIX: put the good value back in the state file.',
              'FAKE-WRONG' => 'FAKE-WRONG: add a notes file explaining the state instead.',
              'FAKE-FAIL' => 'FAKE-FAIL: rewrite the whole module from scratch carefully.',
              _ => 'FAKE-HANG: think about it for a very long time first.',
            }}',
        'files_likely': ['state.txt'],
      },
  ],
});

void main() {
  late Directory scratch;
  late String dmc;
  late String fakeMuse;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_timelines_');
    dmc = await compiledDmc(scratch);
    final source = Isolate.resolvePackageUriSync(
      Uri.parse('package:dmc_doc/doc.dart'),
    )!.toFilePath();
    final docRoot = p.dirname(p.dirname(source));
    fakeMuse = p.join(scratch.path, Platform.isWindows ? 'muse.exe' : 'muse');
    final built = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      p.join(docRoot, 'test', 'support', 'fake_muse.dart'),
      '-o',
      fakeMuse,
    ]);
    expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  late Directory repo;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> answers;
  late List<String> ids;
  late String museLog;
  var counter = 0;

  File file(String name) => File(p.joinAll([repo.path, ...name.split('/')]));

  Future<String> git(List<String> args, {String? directory}) async {
    final result = await Process.run('git', [
      '-C',
      directory ?? repo.path,
      ...args,
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return '${result.stdout}';
  }

  /// One agent turn through dmc's hook. Returns the checkpoint id.
  Future<String> agentTurn(String prompt, void Function() edit) async {
    final session = 'session-${counter++}';
    Future<void> hook(String event) async {
      final process = await Process.start(dmc, [
        'agent-hook',
        'claude-code',
        event,
      ], workingDirectory: repo.path);
      process.stdin.write(
        jsonEncode({
          'hook_event_name': event,
          'session_id': session,
          'prompt_id': 'turn-$counter',
          'cwd': repo.path,
          'prompt': prompt,
        }),
      );
      await process.stdin.close();
      await process.stdout.drain<void>();
      await process.stderr.drain<void>();
      expect(await process.exitCode, 0);
    }

    await hook('UserPromptSubmit');
    edit();
    await hook('Stop');
    final listed = await Process.run(dmc, [
      'checkpoint',
      'list',
      '--limit',
      '1',
      '--json',
    ], workingDirectory: repo.path);
    final latest =
        (((jsonDecode(listed.stdout as String) as Map)['data']
                        as Map)['checkpoints']
                    as List)
                .first
            as Map;
    expect(latest['status'], 'closed');
    return latest['id'] as String;
  }

  /// Every file under the repository except .git, with its bytes: the
  /// working copy and the main .dmc vault.
  Map<String, String> snapshot() => {
    for (final entity in repo.listSync(recursive: true, followLinks: false))
      if (entity is File &&
          p.split(p.relative(entity.path, from: repo.path)).first != '.git')
        p.relative(entity.path, from: repo.path): base64Encode(
          entity.readAsBytesSync(),
        ),
  };

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_timelines_home_');
    repo = Directory(p.join(scratch.path, 'repo ${counter++}'))..createSync();
    museLog = p.join(home.path, 'muse.log');
    await git(['init', '-q']);
    file('state.txt').writeAsStringSync('good\n');
    file('old.txt').writeAsStringSync('committed, later deleted\n');
    file('.gitignore').writeAsStringSync('*.log\n');
    await git(['add', '-A']);
    await git([
      '-c',
      'user.name=t',
      '-c',
      'user.email=t@example.com',
      'commit',
      '-qm',
      'init',
    ]);
    expect(
      (await Process.run(dmc, ['init'], workingDirectory: repo.path)).exitCode,
      0,
    );
    ids = [
      await agentTurn('Turn 1: add a feature', () {
        file('feature1.txt').writeAsStringSync('feature 1\n');
        file('old.txt').deleteSync();
      }),
      await agentTurn('Turn 2: tweak the state', () {
        file('state.txt').writeAsStringSync('bad\n');
        file('feature2.txt').writeAsStringSync('feature 2\n');
      }),
    ];
    out = StringBuffer();
    err = StringBuffer();
    answers = [];
  });

  tearDown(() => home.deleteSync(recursive: true));

  Future<FakeProvider> planner(String reply) async {
    final meta = await FakeProvider.start([
      FakeReply.chat(reply, model: 'muse-wonder-1.0'),
    ]);
    addTearDown(meta.close);
    File(p.join(home.path, 'config', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'providers': {
            'meta': {'baseUrl': meta.baseUrl},
          },
        }),
      );
    return meta;
  }

  Future<int> doc(List<String> args, {TimelineDeps? deps}) => runDoc(
    [...args, '--dmc', dmc, '--workspace', repo.path],
    environment: {
      'DOC_CONFIG_DIR': p.join(home.path, 'config'),
      'DOC_DATA_DIR': p.join(home.path, 'data'),
      'HOME': home.path,
      'PATH': Platform.environment['PATH'] ?? '',
      if (Platform.isWindows)
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'MODEL_API_KEY': 'LLM|meta-key-for-tests-01',
      'DOC_MUSE_BIN': fakeMuse,
      'FAKE_MUSE_LOG': museLog,
    },
    out: out,
    err: err,
    client: ChatClient(maxRetries: 0, sleep: (_) async {}),
    readLine: () => answers.isEmpty ? null : answers.removeAt(0),
    timelines:
        deps ??
        const TimelineDeps(
          statusEvery: Duration(seconds: 1),
          agentTimeout: Duration(seconds: 4),
        ),
  );

  Map runJson() {
    final runs = Directory(p.join(home.path, 'data', 'timelines')).listSync();
    expect(runs, hasLength(1));
    return jsonDecode(
          File(p.join(runs.single.path, 'run.json')).readAsStringSync(),
        )
        as Map;
  }

  Future<Set<String>> branches() async => (await git([
    'branch',
    '--list',
    'doc/timeline/*',
    '--format=%(refname:short)',
  ])).split('\n').where((b) => b.isNotEmpty).toSet();

  test('three timelines from the latest after-state: one fix, one failure, '
      'one timeout; exact base trees; the working copy and the main vault '
      'are untouched; tests and the comparison per timeline', () async {
    final meta = await planner(
      plan([
        ('Put the value back', 'FAKE-FIX'),
        ('Rewrite the module', 'FAKE-FAIL'),
        ('Think first', 'FAKE-HANG'),
      ]),
    );
    final before = snapshot();
    final head = (await git(['rev-parse', 'HEAD'])).trim();
    final statusBefore = await git(['status', '--porcelain']);
    expect(
      await doc([
        'timelines',
        'make the tests pass again',
        '--test',
        goodTest,
        '--max-steps',
        '5',
        '--yes',
      ]),
      0,
      reason: '$out\n$err',
    );
    final text = '$out';

    // The planner got the task, the base facts and file names, as JSON.
    final request = meta.requests.single.body!;
    expect(request['model'], 'muse-wonder-1.0');
    expect(request['response_format'], isNotNull);
    final sent = ((request['messages'] as List)[1] as Map)['content'] as String;
    expect(sent, contains('Task: make the tests pass again'));
    expect(sent, contains('Number of approaches: 3'));
    expect(sent, contains('after state of checkpoint ${ids[1]}'));
    expect(sent, contains('- feature1.txt'));
    expect(sent, isNot(contains('- old.txt')));
    expect(sent, isNot(contains('bad')));

    expect(text, contains('Plan (meta muse-wonder-1.0'));
    expect(text, contains('  1. Put the value back'));
    expect(text, contains('Estimate: at most \$'));
    expect(
      text,
      contains(
        'Run 3 Muse Code agents in separate worktrees (max 5 steps, 10 min each',
      ),
    );

    final run = runJson();
    final id = run['id'] as String;
    final timelines = (run['timelines'] as List).cast<Map>();
    final base = run['base'] as Map;
    expect(base['checkpointId'], ids[1]);
    expect(base['state'], 'after');

    // Worktrees outside the repository, each starting from the exact base.
    for (final t in timelines) {
      final tree = t['worktree'] as String;
      expect(p.isWithin(repo.path, tree), isFalse);
      expect(
        p.isWithin(p.join(home.path, 'data', 'timelines', id), tree),
        isTrue,
      );
      expect(Directory(p.join(tree, '.dmc')).existsSync(), isTrue);
    }
    final baseFiles = (await git([
      'ls-tree', '-r', '--name-only', base['commit'] as String, //
    ])).split('\n').where((f) => f.isNotEmpty).toSet();
    expect(baseFiles, {
      '.gitignore',
      'state.txt',
      'feature1.txt',
      'feature2.txt',
    });
    expect(await git(['show', '${base['commit']}:state.txt']), 'bad\n');
    expect(
      (await git([
        'log',
        '-1',
        '--format=%s',
        base['commit'] as String,
      ])).trim(),
      'timeline base: ${ids[1]} after',
    );

    // Muse ran in each worktree with the verified flags, never --yolo.
    final calls = [
      for (final line in File(museLog).readAsLinesSync())
        jsonDecode(line) as Map,
    ];
    expect(calls, hasLength(3));
    for (final call in calls) {
      final args = (call['args'] as List).cast<String>();
      expect(args.first, 'exec');
      expect(args, containsAllInOrder(['--max-model-steps', '5']));
      expect(args, containsAll(['--disable-web-tools', '--json']));
      expect(args, isNot(contains('--yolo')));
      expect(args, isNot(contains('--disable-approval')));
      expect(args[1], contains('Task: make the tests pass again'));
      String real(String path) => Directory(path).resolveSymbolicLinksSync();
      expect(
        timelines.map((t) => real(t['worktree'] as String)),
        contains(real(call['cwd'] as String)),
      );
    }

    // One fixed and passes, one failed at the step limit, one timed out.
    expect(timelines.map((t) => t['status']), ['done', 'failed', 'timedOut']);
    expect(timelines[0]['steps'], 3);
    expect((timelines[0]['test'] as Map)['passed'], isTrue);
    expect(timelines[0]['files'], [
      {'path': 'state.txt', 'added': 1, 'removed': 1},
    ]);
    expect((timelines[1]['test'] as Map)['passed'], isFalse);
    expect(timelines[1]['reason'], contains('2 step(s)'));
    expect((timelines[2]['test'] as Map)['passed'], isFalse);
    expect(
      timelines[0]['costUsd'],
      closeTo((30000 * 0.10 + 30000 * 0.002 + 300 * 0.20) / 1e6, 1e-9),
    );

    expect(text, contains('[timeline 1] running: Put the value back'));
    expect(text, contains('[timeline 2] stopped at the step limit'));
    expect(text, contains('[timeline 3] timed out'));
    expect(
      text,
      contains('[1] Put the value back\n    agent: done, 3 step(s)'),
    );
    expect(text, contains('    files: state.txt +1 −1\n    tests: PASS'));
    expect(
      text,
      contains('[2] Rewrite the module\n    agent: step limit, 2 step(s)'),
    );
    expect(text, contains('[3] Think first\n    agent: timed out'));
    expect(text, contains('Pick one with: doc timelines pick $id <k>'));

    // Branches hold each agent's commit; the user's repo is untouched.
    expect(await branches(), {for (final t in timelines) t['branch']});
    expect(
      (await git(['log', '-1', '--format=%s', 'doc/timeline/$id/1'])).trim(),
      'timeline 1: Put the value back',
    );
    expect(snapshot(), before);
    expect((await git(['rev-parse', 'HEAD'])).trim(), head);
    expect(await git(['status', '--porcelain']), statusBefore);

    // pick: the diff and the commands, and nothing changes.
    out.clear();
    expect(await doc(['timelines', 'pick', id, '1']), 0, reason: '$err');
    final picked = '$out';
    expect(picked, contains('Timeline 1 of $id: Put the value back'));
    expect(picked, contains('-bad\n+good'));
    expect(picked, contains('git merge --no-ff doc/timeline/$id/1'));
    expect(picked, contains('git apply --3way'));
    expect(picked, contains('doc restore ${ids[1]}'));
    expect(picked, contains('archived as branches (never deleted)'));
    expect(snapshot(), before);
    expect((await git(['rev-parse', 'HEAD'])).trim(), head);
    out.clear();
    expect(await doc(['timelines', 'show', id]), 0);
    expect('$out', contains('(picked)'));
    expect('$out', contains('(archived)'));
    out.clear();
    expect(await doc(['timelines', 'list']), 0);
    expect('$out', contains('$id  done  3 timeline(s), 1 passing, picked 1'));

    // clean: worktree folders go after a yes; branches stay.
    out.clear();
    answers.add('n');
    expect(await doc(['timelines', 'clean', id]), 0);
    expect('$out', contains('Nothing was removed.'));
    expect(Directory(timelines[0]['worktree'] as String).existsSync(), isTrue);
    answers.add('y');
    expect(await doc(['timelines', 'clean', id]), 0, reason: '$err');
    for (final t in timelines) {
      expect(Directory(t['worktree'] as String).existsSync(), isFalse);
    }
    expect(await branches(), {for (final t in timelines) t['branch']});
    expect(snapshot(), before);
  });

  test('--from the before-state of a checkpoint, and --json', () async {
    await planner(plan([('Fix', 'FAKE-FIX'), ('Notes', 'FAKE-WRONG')]));
    expect(
      await doc([
        'timelines',
        'add a third feature',
        '--test',
        goodTest,
        '--from',
        ids[1],
        '--state',
        'before',
        '--n',
        '2',
        '--yes',
        '--json',
      ]),
      0,
      reason: '$err',
    );
    final result = jsonDecode('$out') as Map;
    expect(result['command'], 'doc.timelines');
    expect(result['status'], 'done');
    expect(result['base'], containsPair('state', 'before'));
    expect(result['base'], containsPair('checkpointId', ids[1]));
    expect(result['planner'], containsPair('model', 'muse-wonder-1.0'));
    final timelines = (result['timelines'] as List).cast<Map>();
    expect(timelines, hasLength(2));
    expect(
      timelines.first.keys,
      containsAll([
        'k',
        'approach',
        'branch',
        'worktree',
        'status',
        'steps',
        'costUsd',
        'seconds',
        'commit',
        'files',
        'test',
        'checkpoints',
        'pick',
      ]),
    );
    // The before-state already passes; the notes timeline adds a file.
    expect(timelines.map((t) => (t['test'] as Map)['passed']), [true, true]);
    expect(timelines[1]['files'], [
      {'path': 'notes.txt', 'added': 1, 'removed': 0},
    ]);
    final baseFiles = (await git([
      'ls-tree',
      '-r',
      '--name-only',
      (result['base'] as Map)['commit'] as String, //
    ])).split('\n').where((f) => f.isNotEmpty).toSet();
    expect(baseFiles, {'.gitignore', 'state.txt', 'feature1.txt'});
    // Progress went to stderr.
    expect('$err', contains('[timeline 1] running'));
  });

  test('the planner must give exactly N valid approaches; "no" starts '
      'nothing', () async {
    final meta = await planner(plan([('Only one', 'FAKE-FIX')]));
    final before = snapshot();
    expect(await doc(['timelines', 'fix it', '--test', goodTest, '--yes']), 1);
    expect(meta.requests, hasLength(2));
    expect(
      ((meta.requests[1].body!['messages'] as List).last as Map)['content'],
      contains('Expected exactly 3 approaches, got 1.'),
    );
    expect('$err', contains('Doc refused the plan'));
    expect(await branches(), isEmpty);
    expect(File(museLog).existsSync(), isFalse);

    await planner(
      plan([('A', 'FAKE-FIX'), ('B', 'FAKE-WRONG'), ('C', 'FAKE-FAIL')]),
    );
    answers.add('n');
    out.clear();
    expect(await doc(['timelines', 'fix it', '--test', goodTest]), 0);
    expect('$out', contains('[y/N] Nothing was started.'));
    expect(await branches(), isEmpty);
    expect(File(museLog).existsSync(), isFalse);
    expect(runJson()['status'], 'declined');
    expect(snapshot(), before);
  });

  test('Ctrl-C stops every agent and keeps the worktrees', () async {
    await planner(
      plan([
        ('Slow 1', 'FAKE-HANG'),
        ('Slow 2', 'FAKE-HANG'),
        ('Slow 3', 'FAKE-HANG'),
      ]),
    );
    final interrupts = StreamController<void>();
    addTearDown(interrupts.close);
    // Ctrl-C once all three agents are running.
    final started = Timer.periodic(const Duration(milliseconds: 200), (timer) {
      final log = File(museLog);
      if (log.existsSync() && log.readAsLinesSync().length >= 3) {
        timer.cancel();
        interrupts.add(null);
      }
    });
    addTearDown(started.cancel);
    final clock = Stopwatch()..start();
    final code = await doc(
      ['timelines', 'wait', '--test', goodTest, '--yes'],
      deps: TimelineDeps(
        interrupts: interrupts.stream,
        statusEvery: const Duration(seconds: 1),
        agentTimeout: const Duration(minutes: 5),
      ),
    );
    expect(code, 130, reason: '$out\n$err');
    expect(clock.elapsed, lessThan(const Duration(seconds: 60)));
    final run = runJson();
    expect(run['status'], 'interrupted');
    for (final t in (run['timelines'] as List).cast<Map>()) {
      expect(t['status'], 'stopped');
      expect(Directory(t['worktree'] as String).existsSync(), isTrue);
    }
    expect('$err', contains('stopping all agents'));
    expect(await branches(), hasLength(3));
  });

  test('--local refuses hosted planning', () async {
    final meta = await planner(
      plan([('A', 'FAKE-FIX'), ('B', 'FAKE-WRONG'), ('C', 'FAKE-FAIL')]),
    );
    expect(
      await doc([
        'timelines',
        'fix it',
        '--test',
        goodTest,
        '--local',
        '--yes',
      ]),
      1,
    );
    expect('$err', contains('--local refuses doc timelines'));
    expect(meta.requests, isEmpty);
    expect(await branches(), isEmpty);
  });
}
