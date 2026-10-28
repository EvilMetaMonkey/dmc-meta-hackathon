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
    scratch = Directory.systemTemp.createTempSync('doc_cli_');
    dmc = await compiledDmc(scratch);
    workspace = Directory(p.join(scratch.path, 'work space ü'))..createSync();
    final init = await Process.run(dmc, [
      'init',
    ], workingDirectory: workspace.path);
    expect(init.exitCode, 0, reason: '${init.stdout}${init.stderr}');
    File(p.join(workspace.path, 'app.dart')).writeAsStringSync('v1');
    File(p.join(workspace.path, 'old.txt')).writeAsStringSync('old');
    final begin = await dmcJson([
      'checkpoint',
      'begin',
      '--label',
      'refactor app',
    ]);
    expect(begin['ok'], isTrue, reason: '$begin');
    checkpointId =
        ((begin['data'] as Map)['checkpoint'] as Map)['id'] as String;
    File(p.join(workspace.path, 'app.dart')).writeAsStringSync('v2');
    File(p.join(workspace.path, 'old.txt')).deleteSync();
    File(p.join(workspace.path, '.env')).writeAsStringSync('API_TOKEN=abc');
    final close = await dmcJson(['checkpoint', 'close', checkpointId]);
    expect(close['ok'], isTrue, reason: '$close');
  });

  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  late Directory configDir;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    configDir = Directory.systemTemp.createTempSync('doc_config_');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => configDir.deleteSync(recursive: true));

  void writeConfig({String? meta, String? baseten, String? local}) {
    File(p.join(configDir.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'providers': {
          if (meta != null) 'meta': {'baseUrl': meta},
          if (baseten != null) 'baseten': {'baseUrl': baseten},
          if (local != null) 'local': {'baseUrl': local},
        },
      }),
    );
  }

  Future<int> doc(List<String> args, {Map<String, String> env = const {}}) =>
      runDoc(
        args,
        environment: {
          'DOC_CONFIG_DIR': configDir.path,
          'HOME': configDir.path,
          'PATH': '',
          ...env,
        },
        out: out,
        err: err,
        client: ChatClient(maxRetries: 1, sleep: (_) async {}),
      );

  test('locates the compiled dmc and parses its JSON', () async {
    final client = await DmcClient.locate(explicit: dmc, environment: const {});
    final show = await client.runJson([
      'checkpoint',
      'show',
      checkpointId,
    ], workspace: workspace.path);
    expect(show['ok'], isTrue);
    expect(show['command'], 'checkpoint.show');
    final diff = await client.runJson([
      'checkpoint',
      'diff',
      checkpointId,
    ], workspace: workspace.path);
    final changes = {
      for (final file in ((diff['data'] as Map)['files'] as List).cast<Map>())
        file['path']: file['change'],
    };
    expect(changes, containsPair('app.dart', 'modified'));
    expect(changes, containsPair('old.txt', 'deleted'));
    expect(changes, containsPair('.env', 'created'));

    final viaEnv = await DmcClient.locate(environment: {'DMC_BIN': dmc});
    expect(viaEnv.executable, p.normalize(dmc));
  });

  test('PATH lookup skips incompatible dmc executables', () async {
    if (Platform.isWindows) return;
    final fakeDir = Directory(p.join(configDir.path, 'old-dmc'))..createSync();
    final fake = File(p.join(fakeDir.path, 'dmc'))
      ..writeAsStringSync('#!/bin/sh\necho "usage: dmc <commands...>"\n');
    Process.runSync('chmod', ['755', fake.path]);
    final pathValue = [
      fakeDir.path,
      if (File(appleDmcPath).existsSync()) '/usr/bin',
      p.dirname(dmc),
    ].join(':');
    final found = await DmcClient.locate(environment: {'PATH': pathValue});
    expect(found.executable, p.normalize(dmc));

    final failure = await DmcClient.locate(
      environment: {
        'PATH': [
          fakeDir.path,
          if (File(appleDmcPath).existsSync()) '/usr/bin',
        ].join(':'),
      },
    ).then<Object?>((_) => null, onError: (Object e) => e);
    expect(failure, isA<DmcException>());
    expect('$failure', contains('No compatible dmc'));
    expect('$failure', contains('${fake.path} (is not a compatible dmc'));
    if (File(appleDmcPath).existsSync()) {
      expect('$failure', contains('Disk Mount Conditioner'));
    }

    final explicit = await DmcClient.locate(
      explicit: fake.path,
      environment: const {},
    ).then<Object?>((_) => null, onError: (Object e) => e);
    expect('$explicit', startsWith('--dmc points at'));
  });

  test('summarize sends redacted facts and prints the summary', () async {
    final baseten = await FakeProvider.start([
      FakeReply.chat(
        'The turn modified app.dart, deleted old.txt and added a .env file.',
        reasoning: 'thinking...',
        prompt: 300,
        completion: 40,
      ),
    ]);
    addTearDown(baseten.close);
    writeConfig(baseten: baseten.baseUrl, local: await closedBaseUrl());
    final before = _tree(workspace);
    final code = await doc(
      [
        'summarize',
        checkpointId,
        '--dmc',
        dmc,
        '--workspace',
        workspace.path,
        '--role-provider',
        'summary=baseten',
      ],
      env: {'BASETEN_API_KEY': 'baseten-key-for-tests-01'},
    );
    expect(code, 0, reason: '$err');
    expect('$out', contains('The turn modified app.dart'));
    expect('$out', isNot(contains('thinking')));
    expect('$out', contains('(baseten fake-model; 300 in / 40 out;'));
    final sent = baseten.requests.single;
    final user =
        ((sent.body!['messages'] as List)[1] as Map)['content'] as String;
    expect(user, contains('- app.dart: modified'));
    expect(user, contains('- old.txt: deleted'));
    expect(
      user,
      contains(
        '- .env: created (secret-bearing file name; contents never sent)',
      ),
    );
    expect(user, isNot(contains('abc')));
    expect(sent.body!.containsKey('max_tokens'), isTrue);
    // Doc never writes workspace files.
    expect(_tree(workspace), before);

    out.clear();
    expect(await doc(['usage']), 0);
    expect('$out', contains('baseten'));
    expect('$out', contains('300'));
    expect('$out', contains('\$100.00'));
  });

  test('--show-prompt prints what would be sent and sends nothing', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(baseten.close);
    writeConfig(baseten: baseten.baseUrl);
    final code = await doc(
      [
        'summarize',
        checkpointId,
        '--dmc',
        dmc,
        '--workspace',
        workspace.path,
        '--role-provider',
        'summary=baseten',
        '--show-prompt',
      ],
      env: {'BASETEN_API_KEY': 'baseten-key-for-tests-01'},
    );
    expect(code, 0, reason: '$err');
    expect('$out', contains('Nothing was sent'));
    expect('$out', contains('Redacted: 0 item(s)'));
    expect('$out', contains('"model": "meta-models/muse-spark-open-1026"'));
    expect('$out', isNot(contains('baseten-key-for-tests-01')));
    expect(baseten.requests, isEmpty);
  });

  test('--local with no local server is explained plainly', () async {
    final local = await closedBaseUrl();
    writeConfig(local: local);
    final code = await doc([
      'summarize',
      checkpointId,
      '--dmc',
      dmc,
      '--workspace',
      workspace.path,
      '--local',
    ]);
    expect(code, 1);
    expect('$err', contains('The local model server is not running at $local'));
    expect('$err', contains('run without --local'));
    expect('$err', isNot(contains('FALLBACK')));
  });

  test(
    'summary uses baseten by default, with a logged fireworks fallback',
    () async {
      final baseten = await FakeProvider.start([
        const FakeReply(503, {'error': 'busy'}),
      ]);
      final fireworks = await FakeProvider.start([
        FakeReply.chat('Fallback summary.', prompt: 200, completion: 50),
      ]);
      addTearDown(baseten.close);
      addTearDown(fireworks.close);
      writeConfig(baseten: baseten.baseUrl);
      File(p.join(configDir.path, 'config.json')).writeAsStringSync(
        jsonEncode({
          'providers': {
            'baseten': {'baseUrl': baseten.baseUrl},
            'fireworks': {'baseUrl': fireworks.baseUrl},
          },
        }),
      );
      final code = await doc(
        [
          'summarize',
          checkpointId,
          '--dmc',
          dmc,
          '--workspace',
          workspace.path,
        ],
        env: {
          'BASETEN_API_KEY': 'baseten-key-for-tests-01',
          'FIREWORKS_API_KEY': 'fireworks-key-for-tests-02',
        },
      );
      expect(code, 0, reason: '$err');
      expect('$out', contains('Fallback summary.'));
      expect('$out', contains('fell back from baseten'));
      expect('$err', contains('FALLBACK: role "summary" failed on baseten'));
      expect('$err', isNot(contains('..')));
    },
  );

  test(
    'models shows providers and key status without values; --check probes them',
    () async {
      final meta = await FakeProvider.start([
        FakeReply.chat('ok', prompt: 9, completion: 30),
      ]);
      final baseten = await FakeProvider.start([
        FakeReply.chat('ok', prompt: 9, completion: 2),
      ]);
      addTearDown(meta.close);
      addTearDown(baseten.close);
      writeConfig(
        meta: meta.baseUrl,
        baseten: baseten.baseUrl,
        local: await closedBaseUrl(),
      );
      const metaKey = 'meta-key-never-printed-123';
      final code = await doc(
        ['models', '--check'],
        env: {'MODEL_API_KEY': metaKey},
      );
      final text = '$out';
      expect(text, isNot(contains(metaKey)));
      expect(text, contains('MODEL_API_KEY set'));
      expect(text, contains('BASETEN_API_KEY NOT set'));
      expect(text, contains('modal (your private deployment)'));
      expect(
        text,
        contains(
          'Provider modal (your private deployment): not configured (set providers.modal.baseUrl or DOC_MODAL_BASE_URL)',
        ),
      );
      expect(
        text,
        matches(
          RegExp(r'meta\s+muse-spark-1\.3\s+ok\s+\d+ ms\s+9 in / 30 out'),
        ),
      );
      expect(text, contains('baseten: BASETEN_API_KEY is not set.'));
      expect(text, contains('fireworks: FIREWORKS_API_KEY is not set.'));
      // Modal is opt-in: listed as a provider, but no default role probes it.
      expect(text, isNot(contains('modal: no base URL is configured')));
      expect(text, contains('summary    baseten'));
      expect(meta.requests.single.body!['reasoning_effort'], 'low');
      expect(code, 1);

      out.clear();
      expect(await doc(['models', '--check', '--local']), 1);
      expect('$out', contains('Mode: --local'));
      expect('$out', isNot(contains('Provider modal')));
      expect('$out', contains('The local model server is not running at'));

      out.clear();
      expect(await doc(['usage']), 0);
      expect(
        '$out',
        contains('billed by GPU time on Modal; check the Modal dashboard'),
      );
      expect('$out', contains('fireworks'));
    },
  );
}

Map<String, String> _tree(Directory root) => {
  for (final entity in root.listSync(recursive: true, followLinks: false))
    if (entity is File &&
        p.split(p.relative(entity.path, from: root.path)).first != '.dmc')
      p.relative(entity.path, from: root.path): entity.readAsStringSync(),
};
