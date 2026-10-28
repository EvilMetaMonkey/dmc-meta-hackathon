@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

/// Passes when state.txt says "good".
final String goodTest = Platform.isWindows
    ? 'findstr /c:good state.txt >nul'
    : 'grep -q good state.txt';

const explanation =
    'Turn 3 rewrote state.txt from good to bad. The test greps for "good", '
    'so it now fails. Check the change to state.txt.';

void main() {
  late Directory scratch;
  late String dmc;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_bisect_');
    dmc = await compiledDmc(scratch);
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  late Directory workspace;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> answers;
  var counter = 0;

  File file(String name) =>
      File(p.joinAll([workspace.path, ...name.split('/')]));

  /// One agent turn through dmc's own hook: UserPromptSubmit, the edits,
  /// then Stop. Returns the checkpoint id.
  Future<String> agentTurn(String prompt, Map<String, String> edits) async {
    final session = 'session-${counter++}';
    Future<void> hook(String event) async {
      final process = await Process.start(dmc, [
        'agent-hook',
        'claude-code',
        event,
      ], workingDirectory: workspace.path);
      process.stdin.write(
        jsonEncode({
          'hook_event_name': event,
          'session_id': session,
          'prompt_id': 'turn-$counter',
          'cwd': workspace.path,
          'prompt': prompt,
        }),
      );
      await process.stdin.close();
      await process.stdout.drain<void>();
      await process.stderr.drain<void>();
      expect(await process.exitCode, 0);
    }

    await hook('UserPromptSubmit');
    edits.forEach((name, text) {
      file(name)
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
    });
    await hook('Stop');
    final listed = await Process.run(dmc, [
      'checkpoint',
      'list',
      '--limit',
      '1',
      '--json',
    ], workingDirectory: workspace.path);
    final latest =
        (((jsonDecode(listed.stdout as String) as Map)['data']
                        as Map)['checkpoints']
                    as List)
                .first
            as Map;
    expect(latest['status'], 'closed', reason: '$latest');
    return latest['id'] as String;
  }

  /// Turns whose state.txt after each turn is [states]; state.txt starts
  /// "good". Each turn also writes its own unrelated file.
  Future<List<String>> history(List<String> states) async {
    final ids = <String>[];
    for (var i = 0; i < states.length; i++) {
      ids.add(
        await agentTurn('Turn ${i + 1}: work on feature ${i + 1}', {
          'state.txt': '${states[i]}\n',
          'feature${i + 1}.txt': 'feature ${i + 1}\n',
        }),
      );
    }
    return ids;
  }

  Map<String, String> tree() => {
    for (final entity in workspace.listSync(
      recursive: true,
      followLinks: false,
    ))
      if (entity is File &&
          p.split(p.relative(entity.path, from: workspace.path)).first !=
              '.dmc')
        p.relative(entity.path, from: workspace.path): entity
            .readAsStringSync(),
  };

  Set<String> bisectTemps() => {
    for (final entity in Directory.systemTemp.listSync())
      if (p.basename(entity.path).startsWith('doc-bisect-')) entity.path,
  };

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_bisect_home_');
    workspace = Directory(p.join(scratch.path, 'repo ${counter++}'))
      ..createSync();
    expect(
      (await Process.run(dmc, [
        'init',
      ], workingDirectory: workspace.path)).exitCode,
      0,
    );
    file('state.txt').writeAsStringSync('good\n');
    out = StringBuffer();
    err = StringBuffer();
    answers = [];
  });

  tearDown(() => home.deleteSync(recursive: true));

  void writeConfig(Map<String, String> urls) {
    File(p.join(home.path, 'config', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'providers': {
            for (final entry in urls.entries)
              entry.key: {'baseUrl': entry.value},
          },
        }),
      );
  }

  Future<int> doc(List<String> args) => runDoc(
    [...args, '--dmc', dmc, '--workspace', workspace.path],
    environment: {
      'DOC_CONFIG_DIR': p.join(home.path, 'config'),
      'DOC_DATA_DIR': p.join(home.path, 'data'),
      'HOME': home.path,
      'PATH': Platform.environment['PATH'] ?? '',
      if (Platform.isWindows)
        'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
      'BASETEN_API_KEY': 'baseten-key-for-tests-01',
    },
    out: out,
    err: err,
    client: ChatClient(maxRetries: 0, sleep: (_) async {}),
    readLine: () => answers.isEmpty ? null : answers.removeAt(0),
  );

  test(
    'finds a first bad turn in the middle, explains it, offers a restore',
    () async {
      final baseten = await FakeProvider.start([FakeReply.chat(explanation)]);
      addTearDown(baseten.close);
      writeConfig({'baseten': baseten.baseUrl});
      final ids = await history(['good', 'good', 'bad', 'bad', 'bad']);
      final before = tree();
      final temps = bisectTemps();
      answers.add('n');
      expect(await doc(['bisect', '--test', goodTest]), 0, reason: '$err');
      final text = '$out';
      expect(text, contains('Bisecting 5 checkpoint(s)'));
      expect(
        text,
        contains(
          '[probe 1] before ${ids[0]} (claude-code): Turn 1: work on feature 1  PASS',
        ),
      );
      expect(text, contains('[probe 2] after ${ids[4]} (claude-code)'));
      expect(text, contains('First bad turn: ${ids[2]}'));
      expect(text, contains('Prompt: Turn 3: work on feature 3'));
      expect(
        text,
        contains('Changed: feature3.txt (created), state.txt (modified)'),
      );
      expect(text, contains('Last good point: after ${ids[1]}'));
      expect(
        RegExp(r'\[probe \d\]').allMatches(text).length,
        lessThanOrEqualTo(5),
      );
      expect(text, contains(explanation));
      expect(
        text,
        contains(
          'Restore to before this turn? [y/N] Not restored. You can run: doc restore ${ids[2]}',
        ),
      );
      // The diff of the bad turn and the failing output reached the model.
      final prompt =
          ((baseten.requests.single.body!['messages'] as List)[1]
                  as Map)['content']
              as String;
      expect(prompt, contains('--- state.txt (modified)\n-good\n+bad'));
      expect(prompt, contains('Failing test output (tail):'));
      // Never touches the working copy; leaves no temporary folders.
      expect(tree(), before);
      expect(bisectTemps(), temps);
    },
  );

  test('finds a first bad turn at the start and at the end', () async {
    final first = await history(['bad', 'bad', 'bad']);
    expect(
      await doc(['bisect', '--test', goodTest, '--no-explain']),
      0,
      reason: '$err',
    );
    expect('$out', contains('First bad turn: ${first[0]}'));
    expect('$out', contains('Last good point: before ${first[0]}'));

    // A fresh history in the same workspace: --from limits the range.
    out.clear();
    file('state.txt').writeAsStringSync('good\n');
    final later = await history(['good', 'good', 'bad']);
    expect(
      await doc([
        'bisect',
        '--test',
        goodTest,
        '--no-explain',
        '--from',
        later[0],
      ]),
      0,
      reason: '$err',
    );
    expect('$out', contains('Bisecting 3 checkpoint(s)'));
    expect('$out', contains('First bad turn: ${later[2]}'));
  });

  test('both ends are checked first, with no model call', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final temps = bisectTemps();
    file('state.txt').writeAsStringSync('bad\n');
    await history(['bad', 'bad']);
    expect(await doc(['bisect', '--test', goodTest]), 1);
    expect('$out', contains('The tests already fail before the first turn'));
    expect('$out', contains('No model was called.'));

    out.clear();
    file('state.txt').writeAsStringSync('good\n');
    final passing = await history(['good', 'good']);
    expect(await doc(['bisect', '--test', goodTest, '--from', passing[0]]), 1);
    expect('$out', contains('The tests pass at the latest turn'));
    expect(baseten.requests, isEmpty);
    expect(bisectTemps(), temps, reason: 'removed after a failed bisect too');
  });

  test('invalid checkpoints are skipped and listed', () async {
    await history(['good']);
    // A nested .gitignore makes the next agent begin fail (outside Git).
    file('sub/.gitignore')
      ..createSync(recursive: true)
      ..writeAsStringSync('x\n');
    final invalidSession = 'session-invalid';
    final process = await Process.start(dmc, [
      'agent-hook',
      'claude-code',
      'UserPromptSubmit',
    ], workingDirectory: workspace.path);
    process.stdin.write(
      jsonEncode({
        'session_id': invalidSession,
        'prompt_id': 'p',
        'cwd': workspace.path,
        'prompt': 'blocked turn',
      }),
    );
    await process.stdin.close();
    await process.exitCode;
    File(p.join(workspace.path, 'sub', '.gitignore')).deleteSync();
    await history(['bad']);
    expect(
      await doc(['bisect', '--test', goodTest, '--no-explain']),
      0,
      reason: '$err',
    );
    expect(
      '$out',
      contains('(invalid): only closed checkpoints can be tested.'),
    );
    expect('$out', contains('Bisecting 2 checkpoint(s)'));
  });

  test('a timeout counts as a failure', () async {
    if (Platform.isWindows) return; // Uses sh's sleep.
    await history(['good', 'bad']);
    expect(
      await doc([
        'bisect',
        '--test',
        'if grep -q bad state.txt; then sleep 5; fi; grep -q good state.txt',
        '--timeout',
        '1',
        '--no-explain',
        '--json',
      ]),
      0,
      reason: '$err',
    );
    final result = jsonDecode('$out') as Map;
    final probes = (result['probes'] as List).cast<Map>();
    expect(probes.where((probe) => probe['timedOut'] == true), isNotEmpty);
    expect((result['result'] as Map)['status'], 'found');
    expect(
      (result['result'] as Map)['failingOutputTail'],
      contains('timed out after 1 s'),
    );
  });

  test('--link and --setup give each probe its dependencies', () async {
    if (Platform.isWindows) return; // Uses sh's test.
    // An ignored dependency folder that exports do not contain.
    file('.dmcignore').writeAsStringSync('deps/\n');
    file('deps/lib.txt')
      ..createSync(recursive: true)
      ..writeAsStringSync('dependency\n');
    await history(['good', 'bad']);
    const needsDeps = 'test -f deps/lib.txt && grep -q good state.txt';
    expect(await doc(['bisect', '--test', needsDeps, '--no-explain']), 1);
    expect('$out', contains('The tests already fail before the first turn'));

    out.clear();
    expect(
      await doc([
        'bisect',
        '--test',
        needsDeps,
        '--link',
        'deps',
        '--no-explain',
      ]),
      0,
      reason: '$err',
    );
    expect(
      '$out',
      contains('Warning: --link deps points every probe at your working copy'),
    );
    expect('$out', contains('First bad turn'));

    out.clear();
    expect(
      await doc([
        'bisect',
        '--setup',
        'mkdir -p deps && echo x > deps/lib.txt',
        '--test',
        needsDeps,
        '--no-explain',
      ]),
      0,
      reason: '$err',
    );
    expect('$out', contains('First bad turn'));
    // The working copy's own deps folder was never touched.
    expect(file('deps/lib.txt').readAsStringSync(), 'dependency\n');
  });

  test(
    'cleanup with --link removes only the link, on success and failure',
    () async {
      if (Platform.isWindows) return; // Uses sh's test.
      file('.dmcignore').writeAsStringSync('deps/\n');
      final linked = {
        'deps/lib.txt': 'dependency\n',
        'deps/nested/inner.txt': 'inner\n',
      };
      linked.forEach((name, text) {
        file(name)
          ..createSync(recursive: true)
          ..writeAsStringSync(text);
      });
      Map<String, String> deps() => {
        for (final entity in Directory(
          p.join(workspace.path, 'deps'),
        ).listSync(recursive: true, followLinks: false))
          if (entity is File)
            p.posix.joinAll(
              p.split(p.relative(entity.path, from: workspace.path)),
            ): entity
                .readAsStringSync(),
      };
      void expectDepsIntact() {
        expect(
          FileSystemEntity.typeSync(
            p.join(workspace.path, 'deps'),
            followLinks: false,
          ),
          FileSystemEntityType.directory,
        );
        expect(deps(), linked);
      }

      await history(['good', 'bad']);
      final temps = bisectTemps();
      const needsDeps =
          'test -f deps/nested/inner.txt && grep -q good state.txt';

      // Success: the first bad turn is found.
      expect(
        await doc([
          'bisect',
          '--test',
          needsDeps,
          '--link',
          'deps',
          '--no-explain',
        ]),
        0,
        reason: '$err',
      );
      expect('$out', contains('First bad turn'));
      expectDepsIntact();
      expect(bisectTemps(), temps);

      // Failure: the tests already fail at the good end.
      out.clear();
      expect(
        await doc([
          'bisect',
          '--test',
          'test -f deps/lib.txt && false',
          '--link',
          'deps',
          '--no-explain',
        ]),
        1,
      );
      expect('$out', contains('The tests already fail before the first turn'));
      expectDepsIntact();
      expect(bisectTemps(), temps);

      // Failure: the test command crashes in every probe.
      out.clear();
      expect(
        await doc([
          'bisect',
          '--test',
          'test -f deps/lib.txt && kill -SEGV \$\$',
          '--link',
          'deps',
          '--no-explain',
        ]),
        1,
      );
      expectDepsIntact();
      expect(bisectTemps(), temps);
    },
  );

  test('a suggested setup is never run without a yes', () async {
    file('pubspec.yaml').writeAsStringSync('name: demo\n');
    await history(['good', 'bad']);
    answers.add('n');
    expect(
      await doc(['bisect', '--test', goodTest, '--no-explain']),
      0,
      reason: '$err',
    );
    expect('$out', contains('Suggested setup: dart pub get'));
    expect('$out', contains('Run this setup in each probe? [y/N]'));
  });

  test('a crashing test command still cleans up', () async {
    if (Platform.isWindows) return; // Uses sh's kill.
    await history(['good', 'bad']);
    final temps = bisectTemps();
    expect(
      await doc([
        'bisect',
        '--test',
        'grep -q good state.txt || kill -SEGV \$\$',
        '--no-explain',
      ]),
      0,
      reason: '$err',
    );
    expect('$out', contains('First bad turn'));
    expect(bisectTemps(), temps);
  });

  test('a failed explanation still prints the result', () async {
    final baseten = await FakeProvider.start([
      const FakeReply(500, {'error': 'down'}),
    ]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final ids = await history(['good', 'bad']);
    expect(await doc(['bisect', '--test', goodTest]), 0, reason: '$err');
    expect('$out', contains('First bad turn: ${ids[1]}'));
    expect('$err', contains('No explanation:'));
    expect('$err', contains('The result above stands.'));
  });

  test('--local explains on this Mac and refuses hosted providers', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    final local = await FakeProvider.start([FakeReply.chat(explanation)]);
    addTearDown(baseten.close);
    addTearDown(local.close);
    writeConfig({'baseten': baseten.baseUrl, 'local': local.baseUrl});
    await history(['good', 'bad']);
    expect(
      await doc(['bisect', '--test', goodTest, '--local']),
      0,
      reason: '$err',
    );
    expect('$out', contains(explanation));
    expect(local.requests, hasLength(1));
    expect(baseten.requests, isEmpty);
  });

  test('--json prints one result object', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(explanation)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final ids = await history(['good', 'bad', 'bad']);
    expect(
      await doc(['bisect', '--test', goodTest, '--json']),
      0,
      reason: '$err',
    );
    final result = jsonDecode('$out') as Map;
    expect(
      result.keys,
      containsAll([
        'command',
        'candidates',
        'skipped',
        'probes',
        'result',
        'explanation',
      ]),
    );
    expect(result['command'], 'doc.bisect');
    expect((result['candidates'] as List).map((c) => (c as Map)['id']), ids);
    final found = result['result'] as Map;
    expect(found['status'], 'found');
    expect((found['firstBad'] as Map)['id'], ids[1]);
    expect(
      (found['firstBad'] as Map)['changedFiles'],
      anyElement(equals({'path': 'state.txt', 'change': 'modified'})),
    );
    expect(found['lastGood'], {'checkpointId': ids[0], 'state': 'after'});
    expect(result['explanation'], explanation);
    expect((result['probes'] as List).first, containsPair('state', 'before'));
    // Progress went to stderr, so stdout is exactly one JSON object.
    expect('$err', contains('[probe 1]'));
  });

  test('accepting the restore undoes the bad turn through dmc', () async {
    // Turn 2 breaks state.txt; turn 3 only adds an unrelated file.
    final ids = <String>[
      await agentTurn('Turn 1', {'feature1.txt': 'one\n'}),
      await agentTurn('Turn 2 breaks it', {'state.txt': 'bad\n'}),
      await agentTurn('Turn 3', {'feature3.txt': 'three\n'}),
    ];
    answers.addAll(['y', 'y']);
    expect(
      await doc(['bisect', '--test', goodTest, '--no-explain', '--no-lesson']),
      0,
      reason: '$err',
    );
    expect('$out', contains('First bad turn: ${ids[1]}'));
    expect('$out', contains('Restore would change 1 file(s):'));
    expect(
      '$out',
      contains('  - state.txt: put back the version from before the turn'),
    );
    expect('$out', contains('Restored 1 file(s) through dmc'));
    expect(file('state.txt').readAsStringSync(), 'good\n');
    expect(file('feature3.txt').readAsStringSync(), 'three\n');
  });
}
