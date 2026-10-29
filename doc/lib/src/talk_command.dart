import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'cli.dart';
import 'config.dart';
import 'dmc_client.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'voice_client.dart';
import 'voice_intent.dart';

/// Longest push-to-talk turn.
const Duration talkMaxDuration = Duration(seconds: 30);

/// Sample rate Doc records and converts to.
const int talkSampleRate = 16000;

/// Room for reasoning plus the small routing answer.
const int voiceRouteMaxTokens = 1500;

/// A key press, as `doc talk` reads it.
enum TalkKey { toggle, cancel, interrupt, other }

TalkKey talkKeyFor(int byte) => switch (byte) {
  32 || 10 || 13 => TalkKey.toggle,
  27 => TalkKey.cancel,
  3 => TalkKey.interrupt,
  _ => TalkKey.other,
};

/// The terminal `doc talk` reads keys from. Raw mode must always be undone.
abstract class TalkTerminal {
  bool get hasTerminal;
  void enterRaw();
  void restore();

  /// The next key (blocking for the user, not for Doc).
  Future<TalkKey> readKey();
}

/// The real terminal. Keys are read with `readByteSync` in a helper
/// isolate, so the stdin stream is never listened to and later questions
/// can still use `stdin.readLineSync`. A pending read is always drained
/// before Doc moves on, so no keystroke is lost.
class StdinTalkTerminal implements TalkTerminal {
  bool? _echo;
  bool? _line;

  @override
  bool get hasTerminal => stdin.hasTerminal;

  @override
  void enterRaw() {
    if (!stdin.hasTerminal || _echo != null) return;
    _echo = stdin.echoMode;
    _line = stdin.lineMode;
    stdin
      ..echoMode = false
      ..lineMode = false;
  }

  @override
  void restore() {
    if (_echo == null) return;
    try {
      stdin
        ..lineMode = _line!
        ..echoMode = _echo!;
    } on StdinException {
      // The terminal is gone; nothing to restore.
    }
    _echo = null;
    _line = null;
  }

  @override
  Future<TalkKey> readKey() async {
    final byte = await Isolate.run(stdin.readByteSync);
    return byte < 0 ? TalkKey.cancel : talkKeyFor(byte);
  }
}

/// A running microphone capture: PCM16 mono at [sampleRate].
class Recording {
  final String tool;
  final Stream<List<int>> audio;
  final Future<void> Function() stop;

  const Recording(this.tool, this.audio, this.stop);
}

/// Starts the microphone. Doc talks to Meta itself; the tool only records.
abstract class AudioRecorder {
  Future<Recording> start(int sampleRate);
}

/// What can record or convert audio here: `rec`/`sox`, else `ffmpeg`.
class AudioTools {
  final String? rec;
  final String? sox;
  final String? ffmpeg;

  const AudioTools({this.rec, this.sox, this.ffmpeg});

  static AudioTools find(Map<String, String> environment) {
    String? which(String name) {
      final path = environment['PATH'] ?? environment['Path'] ?? '';
      for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
        if (directory.isEmpty) continue;
        for (final candidate in [
          p.join(directory, name),
          if (Platform.isWindows) p.join(directory, '$name.exe'),
        ]) {
          if (FileSystemEntity.typeSync(candidate) ==
              FileSystemEntityType.file) {
            return candidate;
          }
        }
      }
      return null;
    }

    return AudioTools(
      rec: which('rec'),
      sox: which('sox'),
      ffmpeg: which('ffmpeg'),
    );
  }

  static const String install =
      'Install SoX (macOS: brew install sox, which provides rec) or FFmpeg (brew install ffmpeg).';
}

/// The microphone through `rec` (SoX) or, failing that, `ffmpeg` with
/// AVFoundation (macOS). The first recording asks for the terminal's
/// microphone permission (System Settings → Privacy & Security →
/// Microphone).
class ToolAudioRecorder implements AudioRecorder {
  final AudioTools tools;

  /// The AVFoundation input for ffmpeg (`DOC_MIC_DEVICE`), default `:0`.
  final String ffmpegInput;

  const ToolAudioRecorder(this.tools, {this.ffmpegInput = ':0'});

  @override
  Future<Recording> start(int sampleRate) async {
    final List<String> command;
    final String tool;
    if (tools.rec != null) {
      tool = 'rec (SoX)';
      command = [
        tools.rec!,
        '-q',
        '-t', 'raw', '-b', '16', '-e', 'signed', '-c', '1', //
        '-r', '$sampleRate', '-',
      ];
    } else if (tools.ffmpeg != null && Platform.isMacOS) {
      tool = 'ffmpeg (AVFoundation)';
      command = [
        tools.ffmpeg!,
        '-nostdin', '-hide_banner', '-loglevel', 'error', //
        '-f', 'avfoundation', '-i', ffmpegInput,
        '-ac', '1', '-ar', '$sampleRate', '-f', 's16le', '-',
      ];
    } else {
      throw StateError('No microphone tool found. ${AudioTools.install}');
    }
    final process = await Process.start(
      command.first,
      command.skip(1).toList(),
    );
    final errors = StringBuffer();
    process.stderr
        .transform(const SystemEncoding().decoder)
        .listen(errors.write);
    var stopped = false;
    return Recording(tool, process.stdout, () async {
      if (stopped) return;
      stopped = true;
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    });
  }
}

/// [path] as PCM16 mono at 16 or 24 kHz: read directly when it already is
/// a PCM16 mono WAV, else converted to 16 kHz with sox or ffmpeg.
Future<PcmAudio> loadAudioFile(String path, AudioTools tools) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('No such audio file', path);
  }
  final direct = readPcmWav(file.readAsBytesSync());
  if (direct != null) return direct;
  final List<String> command;
  if (tools.sox != null) {
    command = [
      tools.sox!, path, '-t', 'raw', '-b', '16', '-e', 'signed', '-c', '1', //
      '-r', '$talkSampleRate', '-',
    ];
  } else if (tools.ffmpeg != null) {
    command = [
      tools.ffmpeg!, '-nostdin', '-hide_banner', '-loglevel', 'error', //
      '-i', path, '-ac', '1', '-ar', '$talkSampleRate', '-f', 's16le', '-',
    ];
  } else {
    throw StateError(
      '$path is not a 16-bit mono WAV at 16 or 24 kHz, and nothing can convert it. ${AudioTools.install}',
    );
  }
  final result = await Process.run(
    command.first,
    command.skip(1).toList(),
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'Could not convert $path (${p.basename(command.first)} exit ${result.exitCode}): ${'${result.stderr}'.trim()}',
    );
  }
  return PcmAudio(
    Uint8List.fromList(result.stdout as List<int>),
    talkSampleRate,
  );
}

/// What `doc talk` uses; tests replace each part.
class VoiceDeps {
  final TranscriptionClient transcriber;
  final TalkTerminal terminal;
  final AudioRecorder? recorder;

  /// Pacing for `--file` (tests make it instant).
  final Future<void> Function(Duration)? sleep;

  const VoiceDeps({
    this.transcriber = const MetaRealtimeTranscriber(),
    TalkTerminal? terminal,
    this.recorder,
    this.sleep,
  }) : terminal = terminal ?? const _DefaultTerminal();
}

/// Creates the real terminal lazily (a const default for [VoiceDeps]).
class _DefaultTerminal implements TalkTerminal {
  const _DefaultTerminal();
  static final StdinTalkTerminal _real = StdinTalkTerminal();
  @override
  bool get hasTerminal => _real.hasTerminal;
  @override
  void enterRaw() => _real.enterRaw();
  @override
  void restore() => _real.restore();
  @override
  Future<TalkKey> readKey() => _real.readKey();
}

/// `doc talk [--file <audio>]` (alias `doc hey`): "Hey Doc" push-to-talk.
///
/// Nothing is recorded or sent until a key is pressed (or `--file` is
/// given); audio goes only to Meta's realtime transcription, and only
/// while recording. The transcript is redacted before the routing call,
/// and the routed command runs only after the user says yes.
Future<int> runTalkCommand(DocContext context, VoiceDeps deps) async {
  final args = context.args;
  final out = context.out;
  if (args.rest.length != 1) {
    context.log('Usage: doc talk [--file <audio>] [--yes]');
    return 2;
  }
  if (context.router.localOnly) {
    context.log(
      'doc talk needs Muse Voice Transcribe on Meta: there is no local transcription, so --local refuses it. Nothing was recorded or sent.',
    );
    return 1;
  }
  if (args['show-prompt'] as bool) {
    context.log(
      'doc talk cannot show a prompt without sending audio to Meta first. Use doc restore "<request>" --show-prompt for the restore part.',
    );
    return 2;
  }
  final route = context.router.resolve('voice');
  final provider = route.provider;
  final key = provider.keyEnv == null ? null : context.env[provider.keyEnv];
  if (key == null || key.isEmpty) {
    context.log(
      'doc talk needs ${provider.keyEnv ?? 'a key'} for Muse Voice Transcribe on ${provider.id}. Nothing was recorded.',
    );
    return 1;
  }
  final spent = context.router.usage.forProvider(provider.id).costUsd;
  if (provider.budgetUsd != null && spent >= provider.budgetUsd!) {
    context.log(
      '${provider.id}: the budget of \$${provider.budgetUsd!.toStringAsFixed(2)} is used up. Raise providers.${provider.id}.budgetUsd to continue.',
    );
    return 1;
  }
  final baseUrl = provider.resolvedBaseUrl(context.env);
  final tools = AudioTools.find(context.env);
  final keywords = await _keywords(context);
  final file = args['file'] as String?;
  final live = context.out == stdout && deps.terminal.hasTerminal;

  void partial(String text) {
    if (live) {
      stdout.write('\r\x1b[2K… $text');
    } else {
      out.writeln('  … $text');
    }
  }

  TranscriptionResult result;
  String source;
  if (file != null) {
    // A file: converted, then streamed at real-time pace.
    final PcmAudio audio;
    try {
      audio = await loadAudioFile(file, tools);
    } on Object catch (error) {
      context.log('$error');
      return 1;
    }
    source =
        '$file (${(audio.duration.inMilliseconds / 1000).toStringAsFixed(1)} s)';
    out.writeln(
      'Streaming $source to Muse Voice Transcribe at real-time pace…',
    );
    try {
      result = await deps.transcriber.transcribe(
        baseUrl: baseUrl,
        apiKey: key,
        model: route.model,
        sampleRate: audio.sampleRate,
        audio: pacedFrames(audio.bytes, audio.sampleRate, sleep: deps.sleep),
        onPartial: partial,
        keywords: keywords,
      );
    } on TranscriptionException catch (error) {
      context.log(error.message);
      return 1;
    }
  } else {
    final terminal = deps.terminal;
    if (!terminal.hasTerminal) {
      context.log(
        'doc talk needs a terminal to read Space/Enter. Use doc talk --file <audio> in scripts.',
      );
      return 2;
    }
    final recorder =
        deps.recorder ??
        ToolAudioRecorder(
          tools,
          ffmpegInput: context.env['DOC_MIC_DEVICE'] ?? ':0',
        );
    if (deps.recorder == null &&
        tools.rec == null &&
        (tools.ffmpeg == null || !Platform.isMacOS)) {
      context.log('No microphone tool found. ${AudioTools.install}');
      return 1;
    }
    final outcome = await _recordTurn(
      context,
      terminal,
      recorder,
      deps.transcriber,
      baseUrl: baseUrl,
      apiKey: key,
      model: route.model,
      onPartial: partial,
      keywords: keywords,
    );
    if (live) stdout.writeln();
    if (outcome == null) return 130;
    if (outcome.error != null) {
      context.log(outcome.error!);
      return 1;
    }
    result = outcome.result!;
    source = 'the microphone (${outcome.tool})';
    if (result.cancelled) {
      out.writeln('Cancelled. Nothing more was sent.');
      _recordUsage(context, provider, route.model, result);
      return 0;
    }
  }

  final cost = _recordUsage(context, provider, route.model, result);
  final price = provider.audioPrices[route.model];
  out.writeln(
    '(${provider.id} ${route.model}; ${(result.audioSent.inMilliseconds / 1000).toStringAsFixed(1)} s of audio sent, '
    '${result.billedSeconds} s billed; final transcript ${result.finalLatency.inMilliseconds} ms after the end of the audio; '
    '${price == null ? 'cost unknown (no audio price configured)' : '\$${cost.toStringAsFixed(6)}'})',
  );
  final transcript = result.transcript;
  if (transcript.isEmpty) {
    out.writeln('I heard nothing. Nothing will run.');
    return 1;
  }

  // Route the (redacted) transcript to one command; the model only
  // classifies it.
  final messages = [
    const ChatMessage('system', voiceRouteSystemPrompt),
    ChatMessage('user', 'Transcript: $transcript'),
  ];
  VoiceIntent? intent;
  String? problem;
  var sent = messages;
  RoleCallResult? call;
  for (var attempt = 1; attempt <= 2 && intent == null; attempt++) {
    try {
      call = await context.router.call(
        'workhorse',
        sent,
        maxTokens: voiceRouteMaxTokens,
        responseFormat: voiceRouteResponseFormat(),
      );
    } on ModelCallException catch (error) {
      context.log(
        explainFailure(
          error,
          context.config.providers[error.provider] ??
              context.router.resolve('workhorse').provider,
          role: 'workhorse',
        ),
      );
      out.writeln(
        'I heard: "$transcript", but could not work out what to do. Nothing will run.',
      );
      return 1;
    }
    try {
      intent = parseVoiceIntent(call.result.content);
    } on VoiceRouteRefused catch (error) {
      problem = error.message;
      if (attempt == 1) {
        context.log(
          'The routing answer could not be used ($problem) Asking once more.',
        );
        sent = [
          ...messages,
          ChatMessage('assistant', call.result.content),
          ChatMessage(
            'user',
            'That answer was not usable: $problem Answer again with only the JSON object.',
          ),
        ];
      }
    }
  }
  if (intent == null) {
    out.writeln(
      'I heard: "$transcript", but the routing answer was unusable ($problem). Nothing will run.',
    );
    return 1;
  }
  final action = planVoiceAction(intent, transcript);
  if (!action.runnable) {
    out
      ..writeln('I heard: "$transcript". ${action.declined} Nothing will run.')
      ..writeln(voiceCapabilities());
    return 0;
  }

  // Complete the command line where it depends on the workspace.
  var commandArgs = action.args;
  if (action.command == VoiceCommand.summarizeLatest) {
    final latest = await _latestClosedCheckpoint(context);
    if (latest == null) {
      out.writeln(
        'I heard: "$transcript", but there is no closed checkpoint to summarize.',
      );
      return 1;
    }
    commandArgs = ['summarize', latest];
  } else if (action.command == VoiceCommand.bisect) {
    var test = await _bisectTest(context);
    if (test == null) {
      out.write('Test command for bisect (Enter to cancel): ');
      test = context.readLine()?.trim();
      if (test == null || test.isEmpty) {
        out.writeln('Cancelled. Nothing ran.');
        return 0;
      }
    }
    commandArgs = ['bisect', '--test', test];
  }

  final yes = args['yes'] as bool;
  final question =
      'I heard: "$transcript" → I\'ll run: ${describeDocCommand(commandArgs)}\nRun it? [y/N] ';
  bool agreed;
  if (yes && !action.command.alwaysAsk) {
    out.writeln('${question}yes (--yes)');
    agreed = true;
  } else {
    out.write(question);
    final answer = (context.readLine() ?? '').trim().toLowerCase();
    agreed = answer == 'y' || answer == 'yes';
  }
  if (!agreed) {
    out.writeln('Nothing ran.');
    return 0;
  }
  // The existing command, in-process, with its own previews and questions.
  // --yes is never passed on.
  return context.runSubcommand!([
    ...commandArgs,
    if (args['dmc'] != null) ...['--dmc', args['dmc'] as String],
    if (args['workspace'] != null) ...[
      '--workspace',
      args['workspace'] as String,
    ],
    for (final value in args['role-provider'] as List<String>) ...[
      '--role-provider',
      value,
    ],
  ]);
}

double _recordUsage(
  DocContext context,
  ProviderConfig provider,
  String model,
  TranscriptionResult result,
) {
  final price = provider.audioPrices[model];
  final cost = price == null ? 0.0 : result.billedSeconds * price;
  context.router.usage.record(
    provider.id,
    0,
    0,
    cost,
    audioSeconds: result.billedSeconds,
  );
  return cost;
}

class _TurnOutcome {
  final TranscriptionResult? result;
  final String? error;
  final String tool;

  const _TurnOutcome(this.tool, {this.result, this.error});
}

/// One push-to-talk turn from the microphone. Returns null after Ctrl-C.
/// The terminal is restored on every path.
Future<_TurnOutcome?> _recordTurn(
  DocContext context,
  TalkTerminal terminal,
  AudioRecorder recorder,
  TranscriptionClient transcriber, {
  required String baseUrl,
  required String apiKey,
  required String model,
  required void Function(String) onPartial,
  required List<String> keywords,
}) async {
  final out = context.out;
  StreamSubscription<ProcessSignal>? interrupt;
  Recording? recording;
  terminal.enterRaw();
  try {
    try {
      interrupt = ProcessSignal.sigint.watch().listen((_) {
        terminal.restore();
        stdout.writeln('\nInterrupted. Nothing more was sent.');
        exit(130);
      });
    } on SignalException {
      // Not supported here; the finally block still restores the terminal.
    }
    out.writeln('Press Space or Enter to talk (Esc to cancel)…');
    while (true) {
      final key = await terminal.readKey();
      if (key == TalkKey.toggle) break;
      if (key == TalkKey.cancel) {
        out.writeln('Cancelled. Nothing was recorded or sent.');
        return _TurnOutcome('none', result: _nothing);
      }
      if (key == TalkKey.interrupt) return null;
    }

    try {
      recording = await recorder.start(talkSampleRate);
    } on Object catch (error) {
      return _TurnOutcome('none', error: '$error');
    }
    out.writeln(
      'Recording with ${recording.tool}… press Space or Enter to stop (Esc cancels, ${talkMaxDuration.inSeconds} s at most).',
    );
    final cancel = TranscriptionCancel();
    final stop = Completer<String>();
    var drainAny = false;
    // The key that ends the turn. If the turn ends another way (the time
    // limit, an error), this read is still waited for below, so the next
    // question gets the user's next key, not this one.
    final pendingKey = () async {
      while (true) {
        final key = await terminal.readKey();
        if (drainAny ||
            key == TalkKey.toggle ||
            key == TalkKey.cancel ||
            key == TalkKey.interrupt) {
          if (key != TalkKey.toggle) cancel.cancel();
          if (!stop.isCompleted) stop.complete(key.name);
          return key;
        }
      }
    }();
    final timer = Timer(talkMaxDuration, () {
      if (!stop.isCompleted) stop.complete('limit');
    });
    final started = recording;
    unawaited(stop.future.then((_) => started.stop()));
    TranscriptionResult? result;
    String? error;
    try {
      result = await transcriber.transcribe(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        sampleRate: talkSampleRate,
        audio: framed(started.audio, talkSampleRate),
        onPartial: onPartial,
        cancel: cancel,
        keywords: keywords,
      );
    } on TranscriptionException catch (failure) {
      error = failure.message;
    } finally {
      timer.cancel();
      await started.stop();
    }
    final why = stop.isCompleted ? await stop.future : 'ended';
    if (why == 'limit' || error != null) {
      out.writeln(
        why == 'limit'
            ? '\n${talkMaxDuration.inSeconds} s limit reached. Press any key to continue.'
            : '\nPress any key to continue.',
      );
      drainAny = true;
      if (!stop.isCompleted) stop.complete('drained');
    }
    final last = await pendingKey;
    if (last == TalkKey.interrupt) return null;
    return _TurnOutcome(started.tool, result: result, error: error);
  } finally {
    await interrupt?.cancel();
    terminal.restore();
  }
}

const TranscriptionResult _nothing = TranscriptionResult(
  transcript: '',
  sessionId: null,
  audioProcessedMs: 0,
  audioBytesSent: 0,
  audioSent: Duration.zero,
  finalLatency: Duration.zero,
  partials: 0,
  cancelled: true,
);

/// Recognition hints for Meta (the handshake's `keywords`): the names of
/// files the 10 most recent closed checkpoints changed, without
/// extensions (`auth.py` → `auth`), plus "Doc" and "dmc". Names only,
/// never contents. Empty when there is no dmc workspace.
Future<List<String>> _keywords(DocContext context) async {
  final words = <String>{'Doc', 'dmc'};
  try {
    final dmc = await context.dmc();
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '10',
    ], workspace: context.workspace);
    for (final item
        in ((listed['data'] as Map?)?['checkpoints'] as List? ?? const [])
            .whereType<Map>()) {
      if (item['status'] != 'closed') continue;
      final show = await dmc.runJson([
        'checkpoint',
        'show',
        item['id'] as String,
      ], workspace: context.workspace);
      for (final file
          in ((show['data'] as Map?)?['files'] as List? ?? const [])
              .whereType<Map>()) {
        final change = file['change'];
        if (change == null || change == 'unchanged') continue;
        final name = p.basenameWithoutExtension('${file['path']}');
        if (name.length >= 3 && !name.startsWith('.')) words.add(name);
      }
    }
  } on DmcException {
    // No workspace: no hints.
  }
  return words.take(50).toList();
}

Future<String?> _latestClosedCheckpoint(DocContext context) async {
  try {
    final dmc = await context.dmc();
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '50',
    ], workspace: context.workspace);
    final items =
        ((listed['data'] as Map?)?['checkpoints'] as List? ?? const [])
            .whereType<Map>()
            .where((item) => item['status'] == 'closed')
            .toList()
          ..sort(
            (a, b) => (b['createdAt'] as num).compareTo(a['createdAt'] as num),
          );
    return items.isEmpty ? null : items.first['id'] as String;
  } on DmcException catch (error) {
    context.log(error.message);
    return null;
  }
}

Future<String?> _bisectTest(DocContext context) async {
  try {
    final dmc = await context.dmc();
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '1',
    ], workspace: context.workspace);
    final root = (listed['workspace'] as Map?)?['path'] as String?;
    return root == null ? null : context.config.bisectTestFor(root);
  } on DmcException {
    return null;
  }
}
