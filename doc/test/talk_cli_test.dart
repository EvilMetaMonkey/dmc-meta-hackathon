@Timeout(Duration(minutes: 8))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc_doc/doc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/dmc_fixture.dart';
import 'support/fake_provider.dart';
import 'support/fake_voice.dart';

const heard = 'take me back to before it touched auth';

String route(String command, {double confidence = 0.92, String text = heard}) =>
    jsonEncode({'command': command, 'text': text, 'confidence': confidence});

/// Keys pressed after the given delays.
class FakeTerminal implements TalkTerminal {
  final List<(Duration, TalkKey)> keys;
  var raw = 0;
  var restored = 0;
  var inRaw = false;

  FakeTerminal(this.keys);

  @override
  bool get hasTerminal => true;

  @override
  void enterRaw() {
    raw++;
    inRaw = true;
  }

  @override
  void restore() {
    if (inRaw) restored++;
    inRaw = false;
  }

  @override
  Future<TalkKey> readKey() {
    if (keys.isEmpty) return Completer<TalkKey>().future;
    final (delay, key) = keys.removeAt(0);
    return Future.delayed(delay, () => key);
  }
}

/// A microphone that produces 80 ms of audio every 80 ms until stopped.
class FakeRecorder implements AudioRecorder {
  var started = 0;
  var stopped = false;

  @override
  Future<Recording> start(int sampleRate) async {
    started++;
    final controller = StreamController<List<int>>();
    final frame = pcmSeconds(0.08, sampleRate: sampleRate);
    final timer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => controller.add(frame),
    );
    return Recording('fake mic', controller.stream, () async {
      if (stopped) return;
      stopped = true;
      timer.cancel();
      await controller.close();
    });
  }
}

void main() {
  late Directory scratch;
  late String dmc;

  setUpAll(() async {
    scratch = Directory.systemTemp.createTempSync('doc_talk_');
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
  late List<String> ids;
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

  Future<String> turn(String label, Map<String, String> changes) async {
    final begin = await dmcJson(['checkpoint', 'begin', '--label', label]);
    final id = ((begin['data'] as Map)['checkpoint'] as Map)['id'] as String;
    changes.forEach((name, text) => file(name).writeAsStringSync(text));
    expect((await dmcJson(['checkpoint', 'close', id]))['ok'], isTrue);
    return id;
  }

  setUp(() async {
    home = Directory.systemTemp.createTempSync('doc_talk_home_');
    workspace = Directory(p.join(scratch.path, 'ws ${counter++}'))
      ..createSync();
    expect(
      (await Process.run(dmc, [
        'init',
      ], workingDirectory: workspace.path)).exitCode,
      0,
    );
    file('auth.py').writeAsStringSync('check\n');
    file('app.py').writeAsStringSync('app\n');
    ids = [
      await turn('Use hmac in auth', {'auth.py': 'hmac\n'}),
      await turn('Add health', {'app.py': 'app\nhealth\n'}),
    ];
    out = StringBuffer();
    err = StringBuffer();
    answers = [];
  });

  tearDown(() => home.deleteSync(recursive: true));

  void writeConfig(
    Map<String, String> urls, {
    Map<String, Object?> extra = const {},
  }) {
    File(p.join(home.path, 'config', 'config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'providers': {
            for (final entry in urls.entries)
              entry.key: {'baseUrl': entry.value},
          },
          ...extra,
        }),
      );
  }

  Future<int> doc(
    List<String> args, {
    TalkTerminal? terminal,
    AudioRecorder? recorder,
  }) => runDoc(
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
    readLine: () => answers.isEmpty ? null : answers.removeAt(0),
    voice: VoiceDeps(
      terminal: terminal ?? FakeTerminal([]),
      recorder: recorder ?? FakeRecorder(),
    ),
  );

  /// A WAV recording of [seconds] in the scratch folder.
  String wav(double seconds) {
    final path = p.join(home.path, 'request.wav');
    File(path).writeAsBytesSync(pcmWav(pcmSeconds(seconds), 16000));
    return path;
  }

  Future<(FakeVoiceServer, FakeProvider)> providers({
    FakeVoiceMode mode = FakeVoiceMode.normal,
    String transcript = heard,
    required String routing,
    List<FakeReply> restoreReplies = const [],
    Map<String, Object?> extra = const {},
  }) async {
    final voice = await FakeVoiceServer.start(
      mode: mode,
      partials: ['take', 'take me back'],
      finalTranscript: transcript,
      chatReplies: restoreReplies,
    );
    final baseten = await FakeProvider.start([FakeReply.chat(routing)]);
    addTearDown(voice.close);
    addTearDown(baseten.close);
    writeConfig({
      'meta': voice.baseUrl,
      'baseten': baseten.baseUrl,
    }, extra: extra);
    return (voice, baseten);
  }

  String routingPrompt(FakeProvider baseten) =>
      ((baseten.requests.first.body!['messages'] as List)[1] as Map)['content']
          as String;

  test('--file streams the recording, routes the transcript, and "no" runs '
      'nothing', () async {
    final (voice, baseten) = await providers(routing: route('restore'));
    answers.add('n');
    expect(await doc(['talk', '--file', wav(1.2)]), 0, reason: '$err');
    final text = '$out';
    expect(text, contains('Streaming'));
    expect(text, contains('  … take\n  … take me back\n'));
    expect(text, contains('1.2 s of audio sent, 1 s billed'));
    expect(text, contains('\$0.000050'));
    expect(
      text,
      contains(
        'I heard: "$heard" → I\'ll run: doc restore "$heard"\nRun it? [y/N] Nothing ran.',
      ),
    );
    // Streamed at real-time pace in 80 ms frames.
    expect(voice.audioBytes, 16000 * 2 * 1.2);
    expect(
      (voice.frames.last.at - voice.frames.first.at).inMilliseconds,
      greaterThanOrEqualTo(1000),
    );
    expect(voice.handshakes.single['keywords'], containsAll(['auth', 'app']));
    // The routing call saw the transcript, with a JSON schema; restore did
    // not run (no restore-role call, no plan).
    expect(routingPrompt(baseten), 'Transcript: $heard');
    expect(baseten.requests.single.body!['response_format'], isNotNull);
    expect(voice.chatRequests, isEmpty);
    expect(text, isNot(contains('Plan:')));
    // Usage records the billed audio seconds.
    final usage =
        jsonDecode(
              File(
                p.join(home.path, 'config', 'usage.json'),
              ).readAsStringSync(),
            )
            as Map;
    final meta = (usage['providers'] as Map)['meta'] as Map;
    expect(meta['audioSeconds'], 1);
    expect(meta['costUsd'], closeTo(0.00005, 1e-9));
  });

  test('"yes" runs natural-language restore with the spoken request', () async {
    final (voice, _) = await providers(
      routing: route('restore', text: 'undo everything'),
      restoreReplies: [
        FakeReply.chat(
          jsonEncode({
            'mode': 'go_back_before',
            'checkpoint_id': ids[0],
            'confidence': 0.95,
            'reason': 'It changed auth.py.',
            'alternatives': [],
          }),
        ),
      ],
    );
    final before = file('auth.py').readAsStringSync();
    answers.addAll(['y', 'n']);
    expect(await doc(['talk', '--file', wav(0.4)]), 0, reason: '$err');
    final text = '$out';
    expect(text, contains('Plan: go back to before ${ids[0]}'));
    expect(text, contains('Apply this restore (2 step(s), 2 file(s))? [y/N]'));
    final restorePrompt =
        ((voice.chatRequests.single.body!['messages'] as List)[1]
                as Map)['content']
            as String;
    expect(restorePrompt, contains('Request: $heard'));
    expect(restorePrompt, isNot(contains('undo everything')));
    expect(file('auth.py').readAsStringSync(), before);
  });

  test(
    '--yes never answers "Run it?" for restore; it does for lessons',
    () async {
      await providers(routing: route('restore'));
      expect(await doc(['talk', '--file', wav(0.3), '--yes']), 0);
      expect('$out', contains('Run it? [y/N] Nothing ran.'));

      out.clear();
      await providers(routing: route('lessons', text: 'list my lessons'));
      expect(
        await doc(['talk', '--file', wav(0.3), '--yes']),
        0,
        reason: '$err',
      );
      expect(
        '$out',
        contains('I\'ll run: doc lessons\nRun it? [y/N] yes (--yes)'),
      );
      expect('$out', contains('Lessons: 0'));
    },
  );

  test('unknown or low-confidence requests run nothing and list what Doc '
      'can do', () async {
    await providers(routing: route('unknown', text: 'order a pizza'));
    expect(await doc(['talk', '--file', wav(0.3), '--yes']), 0);
    expect('$out', contains('That is not something Doc can do yet.'));
    expect('$out', contains('I can:\n  - go back to an earlier state'));
    expect('$out', isNot(contains('Run it?')));

    out.clear();
    await providers(routing: route('restore', confidence: 0.3));
    expect(await doc(['talk', '--file', wav(0.3), '--yes']), 0);
    expect(
      '$out',
      contains('Not sure enough what you meant (confidence 0.30)'),
    );
    expect('$out', isNot(contains('Run it?')));
  });

  test('the transcript is redacted before the routing call', () async {
    const secret = 'sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123';
    final (_, baseten) = await providers(
      transcript: 'my key is $secret',
      routing: route('unknown'),
    );
    expect(await doc(['talk', '--file', wav(0.3)]), 0);
    expect(routingPrompt(baseten), isNot(contains(secret)));
    expect(routingPrompt(baseten), contains('[REDACTED'));
  });

  test('bisect takes its test command from the workspace config, and '
      'summarize_latest uses the newest closed checkpoint', () async {
    final root =
        ((await dmcJson(['checkpoint', 'list']))['workspace'] as Map)['path']
            as String;
    await providers(
      routing: route('bisect', text: 'which turn broke the tests'),
      extra: {
        'workspaces': {
          root: {'bisectTest': 'python3 -m unittest'},
        },
      },
    );
    answers.add('n');
    expect(await doc(['talk', '--file', wav(0.3), '--yes']), 0, reason: '$err');
    expect(
      '$out',
      contains(
        'I\'ll run: doc bisect --test "python3 -m unittest"\nRun it? [y/N] Nothing ran.',
      ),
    );

    out.clear();
    await providers(routing: route('summarize_latest'));
    answers.add('n');
    expect(await doc(['talk', '--file', wav(0.3)]), 0, reason: '$err');
    expect('$out', contains('I\'ll run: doc summarize ${ids[1]}'));
  });

  test('--local refuses doc talk and sends nothing', () async {
    final (voice, _) = await providers(routing: route('restore'));
    expect(await doc(['talk', '--file', wav(0.3), '--local']), 1);
    expect('$err', contains('there is no local transcription'));
    expect(voice.sessions, 0);
  });

  test(
    'live: a key starts and stops the turn; the terminal is restored',
    () async {
      final (voice, _) = await providers(routing: route('lessons'));
      final terminal = FakeTerminal([
        (Duration.zero, TalkKey.other),
        (Duration.zero, TalkKey.toggle),
        (const Duration(milliseconds: 700), TalkKey.toggle),
      ]);
      final recorder = FakeRecorder();
      answers.add('n');
      expect(
        await doc(['hey'], terminal: terminal, recorder: recorder),
        0,
        reason: '$err',
      );
      final text = '$out';
      expect(text, contains('Press Space or Enter to talk (Esc to cancel)…'));
      expect(text, contains('Recording with fake mic…'));
      expect(text, contains('I heard: "$heard"'));
      expect(recorder.started, 1);
      expect(recorder.stopped, isTrue);
      expect(voice.endStreams, 1);
      expect(voice.audioBytes, greaterThan(0));
      expect(terminal.raw, 1);
      expect(terminal.restored, 1);
      expect(terminal.inRaw, isFalse);
    },
  );

  test('live: Esc before talking records nothing; Esc while talking sends '
      'nothing more', () async {
    final (voice, _) = await providers(routing: route('lessons'));
    final idle = FakeTerminal([(Duration.zero, TalkKey.cancel)]);
    final unused = FakeRecorder();
    expect(await doc(['talk'], terminal: idle, recorder: unused), 0);
    expect('$out', contains('Cancelled. Nothing was recorded or sent.'));
    expect(unused.started, 0);
    expect(voice.sessions, 0);
    expect(idle.inRaw, isFalse);

    out.clear();
    final talking = FakeTerminal([
      (Duration.zero, TalkKey.toggle),
      (const Duration(milliseconds: 400), TalkKey.cancel),
    ]);
    expect(await doc(['talk'], terminal: talking, recorder: FakeRecorder()), 0);
    expect('$out', contains('Cancelled. Nothing more was sent.'));
    expect(voice.endStreams, 0);
    expect(talking.restored, 1);
    expect('$out', isNot(contains('I heard')));
  });

  test('live: after a 1008 error the terminal is restored and the pending '
      'key is drained', () async {
    final (voice, _) = await providers(
      mode: FakeVoiceMode.policy,
      routing: route('lessons'),
    );
    final terminal = FakeTerminal([
      (Duration.zero, TalkKey.toggle),
      (const Duration(milliseconds: 500), TalkKey.other),
    ]);
    expect(
      await doc(['talk'], terminal: terminal, recorder: FakeRecorder()),
      1,
    );
    expect('$err', contains('1008'));
    expect('$out', contains('Press any key to continue.'));
    expect(terminal.keys, isEmpty);
    expect(terminal.restored, 1);
    expect(terminal.inRaw, isFalse);
    expect(voice.sessions, 1);
  });
}
