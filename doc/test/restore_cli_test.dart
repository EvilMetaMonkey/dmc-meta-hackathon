@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

const draftReply =
    'Title: Keep the config stable\n'
    '## What was tried\nThe turn rewrote a line.\n'
    '## Why it failed\nIt broke the caller.\n'
    '## What to do instead\nChange callers too.';

void main() {
  late Directory scratch;
  late String dmc;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_restore_');
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

  /// A closed checkpoint whose turn changed [changes] (name -> new text).
  Future<String> turn(
    Map<String, String> changes, {
    String label = 'agent turn',
  }) async {
    final begin = await dmcJson(['checkpoint', 'begin', '--label', label]);
    expect(begin['ok'], isTrue, reason: '$begin');
    final id = ((begin['data'] as Map)['checkpoint'] as Map)['id'] as String;
    changes.forEach((name, text) => file(name).writeAsStringSync(text));
    expect((await dmcJson(['checkpoint', 'close', id]))['ok'], isTrue);
    return id;
  }

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_restore_home_');
    workspace = Directory(p.join(scratch.path, 'ws ${counter++}'))
      ..createSync();
    expect(
      (await Process.run(dmc, [
        'init',
      ], workingDirectory: workspace.path)).exitCode,
      0,
    );
    file('price.txt').writeAsStringSync('percent 0-100\n');
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
      'BASETEN_API_KEY': 'baseten-key-for-tests-01',
    },
    out: out,
    err: err,
    client: ChatClient(maxRetries: 0, sleep: (_) async {}),
    readLine: () => answers.isEmpty ? null : answers.removeAt(0),
  );

  String sentPrompt(FakeProvider fake) =>
      ((fake.requests.single.body!['messages'] as List)[1] as Map)['content']
          as String;

  test('the preview is shown and "no" changes nothing', () async {
    final id = await turn({'price.txt': 'percent 0-1\n'});
    answers.add('n');
    expect(await doc(['restore', id]), 0, reason: '$err');
    final text = '$out';
    expect(text, contains('Checkpoint $id (closed): agent turn'));
    expect(text, contains('Restore would change 1 file(s):'));
    expect(
      text,
      contains('  - price.txt: put back the version from before the turn'),
    );
    expect(text, contains('Restore these files? [y/N] Nothing was changed.'));
    expect(file('price.txt').readAsStringSync(), 'percent 0-1\n');
    final show = await dmcJson(['checkpoint', 'show', id]);
    expect((show['data'] as Map)['operations'], isEmpty);
  });

  test(
    '"yes" applies through dmc, then a lesson is offered and drafted',
    () async {
      final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
      addTearDown(baseten.close);
      writeConfig({'baseten': baseten.baseUrl});
      final id = await turn({
        'price.txt': 'percent 0-1\n',
        'new.txt': 'made by the turn\n',
      });
      answers.addAll(['y', '', 'Callers still pass 25 for 25%']);
      expect(await doc(['restore', id]), 0, reason: '$err');
      final text = '$out';
      expect(text, contains('  - new.txt: delete it (the turn created it)'));
      expect(text, contains('Restored 2 file(s) through dmc (operation op_'));
      expect(
        text,
        contains('Draft a lesson from the work you just undid? [Y/n] '),
      );
      expect(text, contains('Draft saved:'));
      expect(text, contains('files:\n  - "new.txt"\n  - "price.txt"\n'));
      expect(file('price.txt').readAsStringSync(), 'percent 0-100\n');
      expect(file('new.txt').existsSync(), isFalse);
      // The abandoned work reaches the model as a diff.
      final prompt = sentPrompt(baseten);
      expect(prompt, contains('a restore undoes it'));
      expect(
        prompt,
        contains('--- price.txt (modified)\n-percent 0-100\n+percent 0-1'),
      );
      expect(prompt, contains('--- new.txt (created)\n+made by the turn'));
      expect(
        text,
        contains('What went wrong? (optional, press Enter to skip) '),
      );
      expect(prompt, contains('User note: Callers still pass 25 for 25%'));
    },
  );

  test('a conflict is shown with dmc\'s reason and never forced', () async {
    final id = await turn({'price.txt': 'percent 0-1\n'});
    file('price.txt').writeAsStringSync('edited after the turn\n');
    answers.add('y');
    expect(await doc(['restore', id, '--yes']), 4);
    final text = '$out';
    expect(
      text,
      contains('dmc will not restore this checkpoint as it stands:'),
    );
    expect(text, contains('price.txt: workspace_drift'));
    expect(text, contains('Doc never forces a restore'));
    expect(text, isNot(contains('Restore these files?')));
    expect(file('price.txt').readAsStringSync(), 'edited after the turn\n');
  });

  test('--no-lesson skips the second question', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final id = await turn({'price.txt': 'percent 0-1\n'});
    answers.add('y');
    expect(await doc(['restore', id, '--no-lesson']), 0, reason: '$err');
    expect('$out', contains('Restored 1 file(s)'));
    expect('$out', isNot(contains('Draft a lesson')));
    expect(baseten.requests, isEmpty);
  });

  test('--last-restore finds a restore done directly with dmc', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    file('other.txt').writeAsStringSync('other v1\n');
    final older = await turn({'price.txt': 'percent 0-1\n'});
    final newer = await turn({'other.txt': 'other v2\n'});
    expect(
      (await dmcJson(['checkpoint', 'restore', older, '--apply']))['ok'],
      isTrue,
    );
    expect(await doc(['lesson', 'draft', '--last-restore']), 0, reason: '$err');
    expect('$out', contains('restored checkpoint $older'));
    expect('$out', isNot(contains(newer)));
    expect('$out', contains('files:\n  - "price.txt"\n'));

    // A later redo reapplies the work, so that restore no longer counts.
    expect(
      (await dmcJson(['checkpoint', 'redo', older, '--apply']))['ok'],
      isTrue,
    );
    out.clear();
    expect(await doc(['lesson', 'draft', '--last-restore']), 1);
    expect('$err', contains('No applied checkpoint restore was found'));
  });

  test('the abandoned diff is redacted before it is sent', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final key = 'AKIA${'Q7' * 8}';
    file('deploy.cfg').writeAsStringSync('region = us\n');
    final id = await turn({'deploy.cfg': 'region = us\naws_key = $key\n'});
    expect(await doc(['lesson', 'draft', id]), 0, reason: '$err');
    final prompt = sentPrompt(baseten);
    expect(prompt, isNot(contains(key)));
    expect(prompt, contains('[REDACTED:'));
    expect('$out', isNot(contains(key)));
  });

  test('--local drafts on this Mac and refuses hosted providers', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    final local = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    addTearDown(local.close);
    writeConfig({'baseten': baseten.baseUrl, 'local': local.baseUrl});
    final id = await turn({'price.txt': 'percent 0-1\n'});
    expect(await doc(['restore', id, '--yes', '--local']), 0, reason: '$err');
    expect('$out', contains('Restore these files? [y/N] yes (--yes)'));
    expect('$out', contains('Draft saved'));
    expect(local.requests, hasLength(1));
    expect(baseten.requests, isEmpty);
  });

  test('a truncated label is passed with a truncation marker', () async {
    final id = await turn(
      {'price.txt': 'percent 0-1\n'},
      label:
          'Change apply_discount so that percent is a fraction between 0 and 1 instead of 0 to…',
    );
    expect(
      await doc(['lesson', 'draft', id, '--show-prompt']),
      0,
      reason: '$err',
    );
    final text = '$out';
    expect(text, contains('Nothing was sent'));
    expect(text, contains('instead of 0 to $truncatedLabelMarker'));
    expect(text, isNot(contains('0 to…')));
  });

  test('restore actions read plainly, and the line diff is compact', () {
    expect(
      describeRestoreAction({
        'expected': {'kind': 'file'},
        'intended': {'kind': 'absent'},
      }),
      'delete it (the turn created it)',
    );
    expect(
      describeRestoreAction({
        'expected': {'kind': 'absent'},
        'intended': {'kind': 'file'},
      }),
      'recreate it (the turn deleted it)',
    );
    final before = [for (var i = 1; i <= 10; i++) 'line $i'].join('\n');
    final after = before.replaceFirst('line 5', 'line five');
    expect(unifiedLineDiff(before, after), [
      ' line 3',
      ' line 4',
      '-line 5',
      '+line five',
      ' line 6',
      ' line 7',
    ]);
  });
}
