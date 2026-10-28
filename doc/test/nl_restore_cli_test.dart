@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

const draftReply =
    'Title: Leave auth alone\n'
    '## What was tried\nThe turn rewrote auth.py.\n'
    '## Why it failed\nIt broke logins.\n'
    '## What to do instead\nAsk first.';

/// The restore role's JSON answer.
String choose(
  String id, {
  String mode = 'go_back_before',
  double confidence = 0.92,
  List<String> alternatives = const [],
}) => jsonEncode({
  'mode': mode,
  'checkpoint_id': id,
  'confidence': confidence,
  'reason': 'That turn changed auth.py.',
  'alternatives': alternatives,
});

void main() {
  late Directory scratch;
  late String dmc;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_nl_restore_');
    dmc = await compiledDmc(scratch);
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  late Directory workspace;
  late StringBuffer out;
  late StringBuffer err;

  /// Answers to questions, in order. A function runs when its turn comes
  /// (to change the working copy between preview and apply), then the next
  /// answer is used.
  late List<Object> answers;
  var counter = 0;

  Future<Map<String, Object?>> dmcJson(List<String> args) async {
    final result = await Process.run(dmc, [
      ...args,
      '--json',
      '--schema-version',
      '1',
    ], workingDirectory: workspace.path);
    return (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
  }

  File file(String name) => File(p.join(workspace.path, name));

  /// A closed checkpoint whose turn applied [changes] (name -> new text, or
  /// null to delete).
  Future<String> turn(String label, Map<String, String?> changes) async {
    final begin = await dmcJson(['checkpoint', 'begin', '--label', label]);
    expect(begin['ok'], isTrue, reason: '$begin');
    final id = ((begin['data'] as Map)['checkpoint'] as Map)['id'] as String;
    changes.forEach((name, text) {
      if (text == null) {
        file(name).deleteSync();
      } else {
        file(name).writeAsStringSync(text);
      }
    });
    final close = await dmcJson(['checkpoint', 'close', id]);
    expect(close['ok'], isTrue, reason: '$close');
    return id;
  }

  /// Four turns, oldest first; the second touches auth.py and the fourth
  /// modifies it again.
  Future<List<String>> history() async => [
    await turn('Add slugify to utils', {'utils.py': 'slugify\n'}),
    await turn('Use hmac in auth', {'auth.py': 'import hmac\ncheck\nlogin\n'}),
    await turn('Add a usage section', {'README.md': 'usage\n'}),
    await turn('Add notes and log logins', {
      'notes.md': 'notes\n',
      'auth.py': 'import hmac\ncheck\nlogin\nlog\n',
    }),
  ];

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

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_nl_restore_home_');
    workspace = Directory(p.join(scratch.path, 'ws ${counter++}'))
      ..createSync();
    expect(
      (await Process.run(dmc, [
        'init',
      ], workingDirectory: workspace.path)).exitCode,
      0,
    );
    file('auth.py').writeAsStringSync('check\nlogin\n');
    file('utils.py').writeAsStringSync('title\n');
    file('README.md').writeAsStringSync('demo\n');
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

  String? readAnswer() {
    while (answers.isNotEmpty) {
      final next = answers.removeAt(0);
      if (next is void Function()) {
        next();
        continue;
      }
      return next as String;
    }
    return null;
  }

  Future<int> doc(List<String> args) => runDoc(
    [...args, '--dmc', dmc, '--workspace', workspace.path],
    environment: {
      'DOC_CONFIG_DIR': p.join(home.path, 'config'),
      'DOC_DATA_DIR': p.join(home.path, 'data'),
      'HOME': home.path,
      'PATH': Platform.environment['PATH'] ?? '',
      'MODEL_API_KEY': 'LLM|meta-key-for-tests-01',
      'BASETEN_API_KEY': 'baseten-key-for-tests-01',
    },
    out: out,
    err: err,
    client: ChatClient(maxRetries: 0, sleep: (_) async {}),
    readLine: readAnswer,
  );

  Future<FakeProvider> meta(List<FakeReply> replies) async {
    final fake = await FakeProvider.start(replies);
    addTearDown(fake.close);
    writeConfig({'meta': fake.baseUrl});
    return fake;
  }

  String prompt(FakeRequest request) =>
      ((request.body!['messages'] as List)[1] as Map)['content'] as String;

  /// Completed restore operations, oldest first: (checkpoint, completedAt).
  Future<List<String>> restoredInOrder() async {
    final listed = await dmcJson(['checkpoint', 'list', '--limit', '100']);
    final done = <(String, int)>[];
    for (final item
        in ((listed['data'] as Map)['checkpoints'] as List).whereType<Map>()) {
      for (final operation
          in (item['operations'] as List? ?? const []).whereType<Map>()) {
        if (operation['direction'] == 'restore' &&
            operation['status'] == 'completed') {
          done.add((
            item['id'] as String,
            (operation['completedAt'] as num).toInt(),
          ));
        }
      }
    }
    done.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final d in done) d.$1];
  }

  test('go_back_before previews every step, then applies newest first, '
      'and offers a lesson for the oldest', () async {
    final ids = await history();
    final fake = await meta([FakeReply.chat(choose(ids[1]))]);
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'meta': fake.baseUrl, 'baseten': baseten.baseUrl});
    answers.addAll(['y', 'y', '']);
    expect(
      await doc(['restore', 'take me back to before it touched auth']),
      0,
      reason: '$err',
    );
    final text = '$out';
    expect(text, contains('Plan: go back to before ${ids[1]}'));
    expect(text, contains('(3 step(s), newest first)'));
    expect(text, contains('  1. ${ids[3]}'));
    expect(text, contains('  3. ${ids[1]}'));
    expect(
      text,
      contains('Files that will change (against the working copy):'),
    );
    expect(
      text,
      contains(
        RegExp(r'auth\.py\s+\+0 −2\s+put back the version from before step 3'),
      ),
    );
    expect(text, contains(RegExp(r'notes\.md\s+\+0 −1\s+delete it')));
    expect(text, contains('Apply this restore (3 step(s), 3 file(s))? [y/N]'));
    expect(text, contains('Restored 3 file(s) in 3 step(s) through dmc.'));
    expect(text, contains('Draft saved:'));
    // Newest first, and the working copy is back to before turn 2.
    expect(await restoredInOrder(), [ids[3], ids[2], ids[1]]);
    expect(tree(), {
      'auth.py': 'check\nlogin\n',
      'utils.py': 'slugify\n',
      'README.md': 'demo\n',
    });
    // The model saw labels and paths, never contents, and a JSON schema.
    final request = fake.requests.single;
    expect(prompt(request), contains('Request: take me back to before it'));
    expect(prompt(request), contains('changed: auth.py (modified)'));
    expect(prompt(request), isNot(contains('import hmac')));
    expect((request.body!['response_format'] as Map)['type'], 'json_schema');
    // The lesson is drafted from the oldest step, with the rest as context.
    final draft = prompt(baseten.requests.single);
    expect(draft, contains('Checkpoint ${ids[1]}'));
    expect(draft, contains('also undid 2 later checkpoint(s)'));
  });

  test('undo_turn restores that one checkpoint only', () async {
    final ids = await history();
    await meta([FakeReply.chat(choose(ids[2], mode: 'undo_turn'))]);
    answers.add('y');
    expect(
      await doc(['restore', 'undo the readme change', '--no-lesson']),
      0,
      reason: '$err',
    );
    expect('$out', contains('Plan: undo only ${ids[2]}'));
    expect(await restoredInOrder(), [ids[2]]);
    expect(file('README.md').readAsStringSync(), 'demo\n');
    expect(file('notes.md').readAsStringSync(), 'notes\n');
  });

  test('"no" leaves the working copy byte-identical', () async {
    final ids = await history();
    await meta([FakeReply.chat(choose(ids[1]))]);
    final before = tree();
    answers.add('n');
    expect(await doc(['restore', 'before auth']), 0, reason: '$err');
    expect('$out', contains('[y/N] Nothing was changed.'));
    expect(tree(), before);
    expect(await restoredInOrder(), isEmpty);
  });

  test('an id that is not a candidate is refused after one retry', () async {
    await history();
    final fake = await meta([FakeReply.chat(choose('cp_mzzzzzzz_00ff'))]);
    final before = tree();
    expect(await doc(['restore', 'before auth', '--yes']), 1);
    expect(fake.requests, hasLength(2));
    expect(
      ((fake.requests[1].body!['messages'] as List).last as Map)['content'],
      contains('That answer was not usable'),
    );
    expect('$out', contains('Doc refused the model\'s answer'));
    expect('$out', contains('not one of the 4 candidate checkpoint(s)'));
    expect(tree(), before);
  });

  test('a malformed answer is retried once and then accepted', () async {
    final ids = await history();
    final fake = await meta([
      FakeReply.chat('Sure! I would go back before the auth turn.'),
      FakeReply.chat(choose(ids[3], mode: 'undo_turn')),
    ]);
    answers.add('n');
    expect(await doc(['restore', 'undo the last one']), 0, reason: '$err');
    expect(fake.requests, hasLength(2));
    expect('$err', contains('could not be used'));
    expect('$out', contains('Plan: undo only ${ids[3]}'));
  });

  test(
    'low confidence shows the choices and needs a pick, even with --yes',
    () async {
      final ids = await history();
      await meta([
        FakeReply.chat(choose(ids[1], confidence: 0.4, alternatives: [ids[3]])),
      ]);
      final before = tree();
      // No pick (Enter).
      answers.add('');
      expect(await doc(['restore', 'before the auth thing', '--yes']), 0);
      final text = '$out';
      expect(text, contains('Doc is not sure enough to pick for you'));
      expect(text, contains('  1. '));
      expect(text, contains('     ${ids[1]}'));
      expect(text, contains('     files: auth.py (modified)'));
      expect(text, contains('  2. '));
      expect(text, contains('     ${ids[3]}'));
      expect(text, contains('Cancelled. Nothing was changed.'));
      expect(text, isNot(contains('Apply this restore')));
      expect(tree(), before);

      // A pick, then --yes answers the apply question.
      out.clear();
      answers.add('2');
      expect(
        await doc(['restore', 'before the auth thing', '--yes', '--no-lesson']),
        0,
        reason: '$err',
      );
      expect('$out', contains('Plan: go back to before ${ids[3]}'));
      expect('$out', contains('[y/N] yes (--yes)'));
      expect(await restoredInOrder(), [ids[3]]);
    },
  );

  test('a conflict in any step\'s preview blocks applying', () async {
    final ids = await history();
    await meta([FakeReply.chat(choose(ids[1]))]);
    // An edit after the last turn, to a file step 2 (README) restores.
    file('README.md').writeAsStringSync('edited by hand\n');
    final before = tree();
    expect(await doc(['restore', 'before auth', '--yes']), 4);
    final text = '$out';
    expect(text, contains('dmc will not restore this plan as it stands:'));
    expect(text, contains('step 2 (${ids[2]}): README.md: workspace_drift'));
    expect(text, isNot(contains('Apply this restore')));
    expect(tree(), before);
    expect(await restoredInOrder(), isEmpty);
  });

  test('a failure mid-apply stops, reports it, and the offered redo puts '
      'the applied steps back', () async {
    final ids = await history();
    await meta([FakeReply.chat(choose(ids[2]))]);
    final before = tree();
    answers.addAll([
      // Between the preview and the apply: README.md, which only step 2
      // (ids[2]) restores, is edited, so step 1 applies and step 2 fails.
      () => file('README.md').writeAsStringSync('edited mid-apply\n'),
      'y',
      'y',
    ]);
    final code = await doc(['restore', 'before the readme', '--no-lesson']);
    expect(code, 4, reason: '$out\n$err');
    final text = '$out';
    expect(text, contains('Step 1 of 2: restored ${ids[3]}'));
    expect(text, contains('Step 2 of 2 (${ids[2]}) failed:'));
    expect(text, contains('README.md: workspace_drift'));
    expect(text, contains('Applied before the failure: ${ids[3]}.'));
    expect(text, contains('Put back the steps already applied? [y/N]'));
    expect(text, contains('Put back ${ids[3]} (dmc redo'));
    // Everything step 1 undid is back; the hand edit is untouched.
    expect(tree(), {...before, 'README.md': 'edited mid-apply\n'});
  });

  test('labels dmc cut are marked truncated, and the request and labels are '
      'redacted', () async {
    await turn(
      'Rotate the key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123 and…',
      {'auth.py': 'rotated\n'},
    );
    final fake = await meta([FakeReply.chat('not json')]);
    expect(
      await doc([
        'restore',
        'before I pasted ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      ]),
      1,
    );
    final sent = prompt(fake.requests.first);
    expect(sent, contains(truncatedLabelMarker));
    expect(
      sent,
      isNot(contains('sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123')),
    );
    expect(sent, isNot(contains('ghp_abcdefghijklmnopqrstuvwxyz0123456789')));
  });

  test('--local asks this Mac and refuses hosted providers', () async {
    final ids = await history();
    final hosted = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(hosted.close);
    final local = await FakeProvider.start([
      FakeReply.chat(choose(ids[3], mode: 'undo_turn')),
    ]);
    addTearDown(local.close);
    writeConfig({
      'meta': hosted.baseUrl,
      'baseten': hosted.baseUrl,
      'local': local.baseUrl,
    });
    answers.add('n');
    expect(
      await doc(['restore', 'undo the last turn', '--local']),
      0,
      reason: '$err',
    );
    expect(hosted.requests, isEmpty);
    expect(local.requests, hasLength(1));
    expect(local.requests.single.body!.containsKey('response_format'), isFalse);
    expect('$out', contains('Plan: undo only ${ids[3]}'));
  });

  test('--json prints the plan and the result as one object', () async {
    final ids = await history();
    await meta([FakeReply.chat(choose(ids[1]))]);
    expect(
      await doc(['restore', 'before auth', '--json', '--yes', '--no-lesson']),
      0,
      reason: '$err',
    );
    final result = jsonDecode('$out') as Map;
    expect(result['command'], 'doc.restore');
    expect(result['request'], 'before auth');
    expect((result['candidates'] as List), hasLength(4));
    expect(
      (result['candidates'] as List).first,
      containsPair('labelTruncated', false),
    );
    expect(result['answer'], containsPair('checkpointId', ids[1]));
    expect(result['model'], containsPair('provider', 'meta'));
    expect(result['model'], containsPair('responseFormat', true));
    expect(result['choice'], {'needed': false});
    expect(result['plan'], containsPair('steps', [ids[3], ids[2], ids[1]]));
    final files = ((result['preview'] as Map)['files'] as List).cast<Map>();
    expect(
      [for (final f in files) f['path']],
      ['README.md', 'auth.py', 'notes.md'],
    );
    expect(files[1], containsPair('removed', 2));
    expect((result['result'] as Map)['status'], 'applied');
    expect(((result['result'] as Map)['applied'] as List), hasLength(3));
    // Questions and progress went to stderr.
    expect('$err', contains('Apply this restore'));
  });

  test('a checkpoint id keeps the checkpoint flow', () async {
    final ids = await history();
    answers.add('n');
    expect(await doc(['restore', ids[3]]), 0, reason: '$err');
    expect('$out', contains('Checkpoint ${ids[3]} (closed): Add notes'));
    expect('$out', contains('Restore these files? [y/N]'));
  });
}
