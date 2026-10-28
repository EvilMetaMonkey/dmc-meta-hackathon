@Timeout(Duration(minutes: 6))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';

void main() {
  late Directory scratch;
  late String dmc;
  late Directory workspace;
  late String checkpointId;

  Future<Map<String, Object?>> dmcJson(List<String> args) async {
    final result = await Process.run(dmc, [
      ...args,
      '--json',
      '--schema-version',
      '1',
    ], workingDirectory: workspace.path);
    return (jsonDecode(result.stdout as String) as Map).cast<String, Object?>();
  }

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_lessons_');
    dmc = await compiledDmc(scratch);
    workspace = Directory(p.join(scratch.path, 'lesson ws'))..createSync();
    expect(
      (await Process.run(dmc, [
        'init',
      ], workingDirectory: workspace.path)).exitCode,
      0,
    );
    File(
      p.join(workspace.path, 'app.py'),
    ).writeAsStringSync('def greet(name):\n    return name\n');
    Directory(p.join(workspace.path, 'src')).createSync();
    File(p.join(workspace.path, 'src', 'util.py')).writeAsStringSync('X = 1\n');
    final begin = await dmcJson([
      'checkpoint',
      'begin',
      '--label',
      'bad rename',
    ]);
    checkpointId =
        ((begin['data'] as Map)['checkpoint'] as Map)['id'] as String;
    File(
      p.join(workspace.path, 'app.py'),
    ).writeAsStringSync('def greet(person):\n    return person\n');
    expect(
      (await dmcJson(['checkpoint', 'close', checkpointId]))['ok'],
      isTrue,
    );
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory home;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> answers;

  setUp(() {
    home = Directory.systemTemp.createTempSync('doc_lesson_home_');
    out = StringBuffer();
    err = StringBuffer();
    answers = [];
  });

  tearDown(() => home.deleteSync(recursive: true));

  /// The summary role on Modal (now also the default), stated explicitly.
  const summaryOnModal = {
    'summary': {
      'provider': 'modal',
      'model': 'muse-glimmer',
      'fallbackProvider': 'baseten',
    },
  };

  void writeConfig(
    Map<String, String> urls, {
    Map<String, Object?> roles = const {},
  }) {
    File(p.join(home.path, 'config', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'providers': {
            for (final entry in urls.entries)
              entry.key: {'baseUrl': entry.value},
          },
          'roles': roles,
        }),
      );
  }

  Future<int> doc(List<String> args, {Map<String, String> env = const {}}) =>
      runDoc(
        [...args, '--dmc', dmc, '--workspace', workspace.path],
        environment: {
          'DOC_CONFIG_DIR': p.join(home.path, 'config'),
          'DOC_DATA_DIR': p.join(home.path, 'data'),
          'HOME': home.path,
          'PATH': Platform.environment['PATH'] ?? '',
          'BASETEN_API_KEY': 'baseten-key-for-tests-01',
          'MODAL_GLIMMER_KEY': 'modal-key-for-tests-02',
          ...env,
        },
        out: out,
        err: err,
        client: ChatClient(maxRetries: 0, sleep: (_) async {}),
        readLine: () => answers.isEmpty ? null : answers.removeAt(0),
      );

  const draftReply =
      'Title: Keep greet()\'s parameter name\n'
      '## What was tried\nThe agent renamed greet\'s parameter.\n'
      '## Why it failed\nCallers pass it by keyword. Token seen: sk-proj-AAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
      '## What to do instead\nKeep the name and add a new function.';

  Future<String> draftAndApprove(FakeProvider baseten) async {
    expect(
      await doc(['lesson', 'draft', checkpointId, '--note', 'Callers broke']),
      0,
      reason: '$err',
    );
    final id = RegExp(
      r'Draft saved: .*[/\\]([^/\\]+)\.md',
    ).firstMatch('$out')![1]!;
    out.clear();
    expect(await doc(['lesson', 'approve', id]), 0, reason: '$err');
    return id;
  }

  test('draft: files come from the checkpoint, secrets are redacted', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    expect(
      await doc([
        'lesson',
        'draft',
        checkpointId,
        '--note',
        'my token is ghp_${'a1B2' * 9}',
      ]),
      0,
      reason: '$err',
    );
    final text = '$out';
    expect(text, contains('files:\n  - "app.py"\n'));
    expect(text, isNot(contains('src/util.py')));
    expect(text, contains('status: "draft"'));
    expect(text, contains('title: "Keep greet()\'s parameter name"'));
    expect(text, contains('[REDACTED:openai_key]'));
    expect(text, isNot(contains('sk-proj-AAAA')));
    final sent =
        ((baseten.requests.single.body!['messages'] as List)[1]
                as Map)['content']
            as String;
    expect(sent, contains('- app.py: modified'));
    expect(sent, contains('User note: my token is [REDACTED:github_token]'));
    expect(sent, isNot(contains('ghp_')));

    // Drafts are never in the library.
    out.clear();
    expect(await doc(['lessons']), 0);
    expect('$out', contains('Lessons: 0'));
    expect('$out', contains('Drafts waiting for approval (not matched)'));
  });

  test('approve moves a draft into the library; reject deletes one', () async {
    final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    writeConfig({'baseten': baseten.baseUrl});
    final id = await draftAndApprove(baseten);
    expect('$out', contains('Approved $id'));
    out.clear();
    expect(await doc(['lessons', '--files', 'app.py']), 0);
    expect('$out', contains('Lessons: 1 covering app.py'));
    expect('$out', contains(id));
    out.clear();
    expect(await doc(['lesson', 'show', id]), 0);
    expect('$out', contains('status: "approved"'));

    expect(await doc(['lesson', 'draft', checkpointId]), 0);
    final second = RegExp(
      r'Draft saved: .*[/\\]([^/\\]+)\.md',
    ).firstMatch('$out')![1]!;
    expect(await doc(['lesson', 'reject', second]), 0);
    expect(await doc(['lesson', 'approve', second]), 1);
    out.clear();
    expect(await doc(['lessons', 'path']), 0);
    expect('$out', contains(p.join(home.path, 'data', 'lessons')));
  });

  test(
    'approve refuses a draft that gained a secret or lost its files',
    () async {
      final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
      addTearDown(baseten.close);
      writeConfig({'baseten': baseten.baseUrl});
      expect(await doc(['lesson', 'draft', checkpointId]), 0);
      final path = RegExp(r'Draft saved: (.*\.md)').firstMatch('$out')![1]!;
      final file = File(path);
      file.writeAsStringSync('${file.readAsStringSync()}\nAKIA${'Q7' * 8}\n');
      expect(await doc(['lesson', 'approve', path]), 1);
      expect('$err', contains('looks like a secret'));
      file.writeAsStringSync(
        file.readAsStringSync().replaceFirst('  - "app.py"\n', ''),
      );
      expect(await doc(['lesson', 'approve', path]), 1);
      expect('$err', contains('files is empty'));
    },
  );

  test('--show-prompt and --local work for drafts', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    final local = await FakeProvider.start([FakeReply.chat(draftReply)]);
    addTearDown(baseten.close);
    addTearDown(local.close);
    writeConfig({'baseten': baseten.baseUrl, 'local': local.baseUrl});
    expect(await doc(['lesson', 'draft', checkpointId, '--show-prompt']), 0);
    expect('$out', contains('Nothing was sent'));
    expect(baseten.requests, isEmpty);
    out.clear();
    expect(
      await doc(['lesson', 'draft', checkpointId, '--local']),
      0,
      reason: '$err',
    );
    expect(local.requests, hasLength(1));
    expect(baseten.requests, isEmpty);
    expect('$out', contains('Draft saved'));
  });

  test(
    'brief: no match means no model call; a match is condensed by the summary role',
    () async {
      final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
      final modal = await FakeProvider.start([
        FakeReply.chat(
          'Before you start: keep greet()\'s parameter name in app.py; add a new function instead.',
        ),
      ]);
      addTearDown(baseten.close);
      addTearDown(modal.close);
      writeConfig({
        'baseten': baseten.baseUrl,
        'modal': modal.baseUrl,
      }, roles: summaryOnModal);
      await draftAndApprove(baseten);

      out.clear();
      expect(await doc(['lesson', 'brief', '--task', 'Update the README']), 0);
      expect('$out', contains('No lessons match'));
      expect(modal.requests, isEmpty);

      out.clear();
      expect(
        await doc([
          'lesson',
          'brief',
          '--task',
          'Add a farewell function to app.py',
        ]),
        0,
        reason: '$err',
      );
      expect('$out', startsWith('Before you start: keep greet()'));
      expect('$out', contains('Matched 1 lesson(s) on app.py'));
      expect('$out', contains('(score 1: app.py)'));
      final body = modal.requests.single.body!;
      expect(
        ((body['messages'] as List).first as Map)['content'],
        startsWith('Reasoning strength: low.'),
      );
    },
  );

  test(
    'start passes the right first prompt for yes, no and no match',
    () async {
      if (Platform.isWindows) return; // The fake agent is a shell script.
      final baseten = await FakeProvider.start([FakeReply.chat(draftReply)]);
      final modal = await FakeProvider.start([
        FakeReply.chat('Before you start: keep the parameter name.'),
      ]);
      addTearDown(baseten.close);
      addTearDown(modal.close);
      writeConfig({
        'baseten': baseten.baseUrl,
        'modal': modal.baseUrl,
      }, roles: summaryOnModal);
      await draftAndApprove(baseten);

      final record = File(p.join(home.path, 'agent-argv.txt'));
      final fakeAgent = File(
        p.join(home.path, 'fake-muse'),
      )..writeAsStringSync('#!/bin/sh\nprintf "%s" "\$1" > "${record.path}"\n');
      Process.runSync('chmod', ['755', fakeAgent.path]);
      final env = {'DOC_MUSE_BIN': fakeAgent.path};
      const task = 'Add a farewell function to app.py';

      expect(
        await doc(['start', 'muse-code', task, '--yes'], env: env),
        0,
        reason: '$err',
      );
      expect(
        record.readAsStringSync(),
        'Before you start: keep the parameter name.\n\n$task',
      );

      answers.add('n');
      expect(await doc(['start', 'muse-code', task], env: env), 0);
      expect('$out', contains("Add this to the agent's first prompt? [y/N]"));
      expect(record.readAsStringSync(), task);

      answers.add('y');
      expect(await doc(['start', 'muse-code', task], env: env), 0);
      expect(record.readAsStringSync(), startsWith('Before you start:'));

      out.clear();
      expect(
        await doc([
          'start',
          'muse-code',
          'Update the README',
          '--yes',
        ], env: env),
        0,
      );
      expect('$out', contains('No lessons match this task'));
      expect(record.readAsStringSync(), 'Update the README');
    },
  );
}
