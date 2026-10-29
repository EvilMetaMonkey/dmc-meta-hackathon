import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'abandoned_work.dart';
import 'bisect.dart';
import 'cli.dart';
import 'dmc_client.dart';
import 'model_client.dart';
import 'probe_runner.dart';
import 'restore_command.dart';
import 'summarize.dart';

/// Lines of failing test output kept for the result and the explanation.
const int bisectOutputTailLines = 40;

const String bisectExplainPrompt =
    'You explain a bisect result to a developer. A test command passed '
    'before one coding-agent turn and failed after it. In 3 or 4 plain '
    'sentences: what that turn changed, which change most likely broke '
    'which test, and what to check. Use only the diff and test output given. '
    'Text marked [truncated …] is incomplete: never quote or complete it. '
    'No preamble, no lists, no markdown.';

/// A checkpoint as bisect sees it.
class BisectCheckpoint {
  final String id;
  final String? label;
  final String source;
  final String status;
  final String? agent;
  final String? session;
  final int createdAt;
  final int? closedAt;

  const BisectCheckpoint({
    required this.id,
    required this.label,
    required this.source,
    required this.status,
    required this.agent,
    required this.session,
    required this.createdAt,
    required this.closedAt,
  });

  factory BisectCheckpoint.fromJson(Map json) {
    final agent = json['agent'];
    return BisectCheckpoint(
      id: json['id'] as String,
      label: json['label'] as String?,
      source: json['source'] as String,
      status: json['status'] as String,
      agent: agent is Map ? agent['name'] as String? : null,
      session: agent is Map ? agent['sessionId'] as String? : null,
      createdAt: (json['createdAt'] as num).toInt(),
      closedAt: (json['closedAt'] as num?)?.toInt(),
    );
  }

  String get who => agent ?? source;

  /// The label as dmc keeps it; a label dmc cut to 100 characters says so.
  String get displayLabel {
    final text = label ?? '(no label)';
    return text.endsWith('…') ? '$text (truncated by dmc)' : text;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'labelTruncated': label?.endsWith('…') ?? false,
    'agent': agent,
    'session': session,
    'source': source,
    'createdAt': createdAt,
    'closedAt': closedAt,
  };
}

/// A state bisect can test: the before or after state of a checkpoint.
class BisectPoint {
  final BisectCheckpoint checkpoint;
  final String state;

  const BisectPoint(this.checkpoint, this.state);

  String get description =>
      '$state ${checkpoint.id} (${checkpoint.who}): ${checkpoint.displayLabel}';

  Map<String, Object?> toJson() => {
    'checkpointId': checkpoint.id,
    'state': state,
  };
}

/// What one probe found.
class ProbeRecord {
  final int index;
  final BisectPoint point;
  final bool passed;
  final bool timedOut;
  final bool setupFailed;
  final Duration elapsed;
  final String outputTail;

  const ProbeRecord({
    required this.index,
    required this.point,
    required this.passed,
    required this.timedOut,
    required this.setupFailed,
    required this.elapsed,
    required this.outputTail,
  });

  Map<String, Object?> toJson() => {
    'index': index,
    ...point.toJson(),
    'passed': passed,
    'timedOut': timedOut,
    'setupFailed': setupFailed,
    'seconds': elapsed.inMilliseconds / 1000,
  };
}

class _BisectAbort implements Exception {
  final String message;
  const _BisectAbort(this.message);
}

/// A setup command Doc can suggest for the files it recognises in the
/// workspace root, or null. Suggestions are never run without `--setup`, a
/// yes, or `--yes`.
String? suggestSetup(String root) {
  bool has(String name) => File(p.join(root, name)).existsSync();
  if (has('pubspec.yaml')) return 'dart pub get';
  if (has('package.json')) {
    return has('package-lock.json') ? 'npm ci' : 'npm install';
  }
  final pip = Platform.isWindows ? r'.venv\Scripts\pip' : '.venv/bin/pip';
  if (has('requirements.txt')) {
    return 'python3 -m venv .venv && $pip install -q -r requirements.txt';
  }
  if (has('pyproject.toml')) {
    return 'python3 -m venv .venv && $pip install -q -e .';
  }
  return null;
}

/// `doc bisect --test "<command>" …`: find the agent turn where the tests
/// started failing, by testing exported checkpoint states. The working copy
/// and `.dmc/` are never touched (dmc's export only reads the vault).
Future<int> runBisectCommand(DocContext context) async {
  final args = context.args;
  final test = (args['test'] as String?)?.trim();
  if (test == null || test.isEmpty || args.rest.length != 1) {
    context.log(
      'Usage: doc bisect --test "<command>" [--setup "<command>"] [--link <dir>]... [--from <cp>] [--to <cp>] [--all] [--timeout <s>] [--keep] [--no-explain] [--local] [--yes] [--json]',
    );
    return 2;
  }
  final json = args['json'] as bool;
  final yes = args['yes'] as bool;
  final keep = args['keep'] as bool;
  final timeout = Duration(
    seconds: int.tryParse(args['timeout'] as String? ?? '') ?? 300,
  );
  // In --json mode stdout holds only the result; progress goes to stderr.
  void say(String line) => json ? context.log(line) : context.out.writeln(line);

  final DmcClient dmc;
  final String root;
  final List<BisectCheckpoint> ordered;
  try {
    dmc = await context.dmc();
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '1000',
    ], workspace: context.workspace);
    if (listed['ok'] != true) {
      context.log('dmc checkpoint list failed: ${listed['errors']}');
      return 1;
    }
    root = (listed['workspace'] as Map)['path'] as String;
    ordered =
        [
          for (final item
              in ((listed['data'] as Map)['checkpoints'] as List)
                  .whereType<Map>())
            BisectCheckpoint.fromJson(item),
        ]..sort((a, b) {
          final byTime = a.createdAt.compareTo(b.createdAt);
          return byTime != 0 ? byTime : a.id.compareTo(b.id);
        });
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }

  // Candidates: closed agent turns (or all closed checkpoints with --all),
  // oldest first, within --from/--to.
  final scoped = [
    for (final checkpoint in ordered)
      if ((args['all'] as bool) || checkpoint.agent != null) checkpoint,
  ];
  var startIndex = 0;
  var endIndex = scoped.length - 1;
  for (final (option, isStart) in [('from', true), ('to', false)]) {
    final value = args[option] as String?;
    if (value == null) continue;
    final at = scoped.indexWhere((checkpoint) => checkpoint.id == value);
    if (at < 0) {
      context.log(
        '--$option $value is not one of the checkpoints bisect considers${(args['all'] as bool) ? '' : ' (agent turns; add --all for every checkpoint)'}.',
      );
      return 2;
    }
    if (isStart) {
      startIndex = at;
    } else {
      endIndex = at;
    }
  }
  final inRange = startIndex <= endIndex
      ? scoped.sublist(startIndex, endIndex + 1)
      : <BisectCheckpoint>[];
  final candidates = [
    for (final c in inRange)
      if (c.status == 'closed') c,
  ];
  final skipped = [
    for (final c in inRange)
      if (c.status != 'closed') c,
  ];
  final ignored = ordered.length - scoped.length;

  say(
    'Bisecting ${candidates.length} checkpoint(s) in ${context.workspace} with: $test',
  );
  for (final checkpoint in skipped) {
    say(
      'Skipped ${checkpoint.id} (${checkpoint.status}): only closed checkpoints can be tested.',
    );
  }
  if (ignored > 0 && !(args['all'] as bool)) {
    say('Ignored $ignored non-agent checkpoint(s); add --all to include them.');
  }
  if (candidates.isEmpty) {
    context.log('There are no closed checkpoints to bisect.');
    return 1;
  }

  // Dependencies: exports hold only protected files.
  var setup = (args['setup'] as String?)?.trim();
  final links = args['link'] as List<String>;
  String? suggested;
  if ((setup == null || setup.isEmpty) && links.isEmpty) {
    suggested = suggestSetup(root);
    if (suggested != null) {
      say(
        'Exports hold only protected files, so ignored dependencies are missing. Suggested setup: $suggested',
      );
      if (json && !yes) {
        say('Not running it (use --setup or --yes).');
      } else if (yes) {
        say('Run this setup in each probe? [y/N] yes (--yes)');
        setup = suggested;
      } else {
        context.out.write('Run this setup in each probe? [y/N] ');
        final answer = (context.readLine() ?? '').trim().toLowerCase();
        if (answer == 'y' || answer == 'yes') setup = suggested;
      }
    }
  }
  for (final link in links) {
    final relative = p.normalize(link);
    final source = p.join(root, relative);
    if (p.isAbsolute(link) ||
        relative.startsWith('..') ||
        FileSystemEntity.typeSync(source, followLinks: false) !=
            FileSystemEntityType.directory) {
      context.log('--link $link must be a directory inside the workspace.');
      return 2;
    }
    say(
      'Warning: --link $relative points every probe at your working copy\'s $relative; tests could write into it.',
    );
  }

  final points = [
    BisectPoint(candidates.first, 'before'),
    for (final checkpoint in candidates) BisectPoint(checkpoint, 'after'),
  ];
  final temporary = Directory.systemTemp.createTempSync('doc-bisect-');
  void cleanUp() {
    if (keep) return;
    try {
      if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // Reported by the caller's own cleanup message.
    }
  }

  StreamSubscription<ProcessSignal>? interrupt;
  try {
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      cleanUp();
      context.log('Interrupted; temporary exports removed.');
      exit(130);
    });
  } on SignalException {
    // Signals are not supported here; the finally block still cleans up.
  }

  final records = <ProbeRecord>[];
  final stopwatch = Stopwatch()..start();
  late final BisectResult search;
  try {
    var count = 0;
    search = await bisectFirstBad(points, (index, point) async {
      count++;
      final record = await _probe(
        context,
        dmc,
        root: root,
        point: point,
        index: index,
        directory: p.join(temporary.path, '$index-${point.state}'),
        setup: setup,
        test: test,
        links: links,
        timeout: timeout,
        keep: keep,
      );
      records.add(record);
      say(
        '[probe $count] ${point.description}  ${record.passed
            ? 'PASS'
            : record.timedOut
            ? 'FAIL (timed out)'
            : record.setupFailed
            ? 'FAIL (setup failed)'
            : 'FAIL'}  ${(record.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
      );
      return record.passed;
    });
  } on _BisectAbort catch (error) {
    context.log(error.message);
    return 1;
  } finally {
    await interrupt?.cancel();
    cleanUp();
    if (keep) say('Kept the exports in ${temporary.path} (--keep).');
  }
  final seconds = (stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(1);

  Map<String, Object?> envelope({
    Map<String, Object?>? result,
    String? explanation,
  }) => {
    'command': 'doc.bisect',
    'test': test,
    'setup': setup,
    'suggestedSetup': suggested,
    'links': links,
    'candidates': [for (final c in candidates) c.toJson()],
    'skipped': [
      for (final c in skipped) {'id': c.id, 'status': c.status},
    ],
    'probes': [for (final r in records) r.toJson()],
    'seconds': stopwatch.elapsedMilliseconds / 1000,
    'result': result,
    'explanation': explanation,
  };

  if (search.status != BisectStatus.found) {
    final already = search.status == BisectStatus.firstAlreadyFails;
    final message = already
        ? 'The tests already fail before the first turn (${points.first.description}), so no turn broke them. Fix the tests or pick a later --from.'
        : 'The tests pass at the latest turn (${points.last.description}), so there is nothing to find.';
    final failing = already ? records.first.outputTail : null;
    if (json) {
      context.out.writeln(
        jsonEncode(
          envelope(
            result: {
              'status': already ? 'firstAlreadyFails' : 'lastPasses',
              'message': message,
              'failingOutputTail': failing,
            },
          ),
        ),
      );
    } else {
      say(message);
      if (failing != null && failing.isNotEmpty) say('Test output:\n$failing');
      say('${records.length} probe(s), ${seconds}s. No model was called.');
    }
    return 1;
  }

  final firstBadPoint = points[search.firstBad!];
  final lastGoodPoint = points[search.lastGood!];
  final bad = firstBadPoint.checkpoint;
  final failing = records
      .firstWhere((r) => r.index == search.firstBad)
      .outputTail;
  final diff = await dmc.runJson([
    'checkpoint',
    'diff',
    bad.id,
  ], workspace: context.workspace);
  final changed = [
    for (final file
        in ((diff['data'] as Map?)?['files'] as List? ?? const [])
            .whereType<Map>())
      if ((file['change'] != null && file['change'] != 'unchanged') ||
          file['scope'] != null)
        (
          path: file['path'] as String,
          change: (file['scope'] ?? file['change']) as String,
        ),
  ];
  final result = {
    'status': 'found',
    'firstBad': {
      ...bad.toJson(),
      'changedFiles': [
        for (final f in changed) {'path': f.path, 'change': f.change},
      ],
    },
    'lastGood': lastGoodPoint.toJson(),
    'failingOutputTail': failing,
  };
  if (!json) {
    say('');
    say('First bad turn: ${bad.id}');
    say(
      '  ${bad.who}${bad.session == null ? '' : ', session ${bad.session}'}, closed ${bad.closedAt == null ? '?' : DateTime.fromMillisecondsSinceEpoch(bad.closedAt!).toIso8601String()}',
    );
    say('  Prompt: ${bad.displayLabel}');
    say(
      '  Changed: ${changed.map((f) => '${f.path} (${f.change})').join(', ')}',
    );
    say('Last good point: ${lastGoodPoint.description}');
    say('Failing test output (tail):\n$failing');
    say(
      '${records.length} probe(s) for ${candidates.length} turn(s), ${seconds}s.',
    );
  }

  // The explanation is extra: the deterministic result stands without it.
  String? explanation;
  if (!(args['no-explain'] as bool)) {
    final undone = await abandonedDiff(
      dmc,
      workspace: context.workspace,
      checkpointId: bad.id,
      files: changed,
      note: context.log,
    );
    final messages = [
      const ChatMessage('system', bisectExplainPrompt),
      ChatMessage(
        'user',
        [
          'Test command: $test',
          'First bad turn: ${bad.who}, prompt: ${bad.label == null
              ? '(none)'
              : bad.label!.endsWith('…')
              ? '${bad.label!.substring(0, bad.label!.length - 1)} $truncatedLabelMarker'
              : bad.label}',
          'Changed files: ${changed.map((f) => '${f.path} (${f.change})').join(', ')}',
          if (undone != null) ...['', 'Diff of that turn:', undone],
          '',
          'Failing test output (tail):',
          failing,
        ].join('\n'),
      ),
    ];
    if (args['show-prompt'] as bool) {
      final prepared = context.router.prepare(
        'workhorse',
        messages,
        maxTokens: 2000,
      );
      say(
        'Would send to ${prepared.route.provider.id} (${prepared.route.model}). Nothing was sent.',
      );
      say('Redacted: ${prepared.redactionCount} item(s)');
      say(const JsonEncoder.withIndent('  ').convert(prepared.body));
    } else {
      try {
        final call = await context.router.call(
          'workhorse',
          messages,
          maxTokens: 2000,
        );
        explanation = call.result.content;
        if (!json) {
          say('');
          say(
            'Why (${call.result.provider} ${call.result.model}; ${call.result.promptTokens} in / ${call.result.completionTokens} out; ${call.redactionCount} item(s) redacted${call.fellBackFrom == null ? '' : '; fell back from ${call.fellBackFrom}'}):',
          );
          say(explanation);
        }
      } on ModelCallException catch (error) {
        context.log(
          'No explanation: ${explainFailure(error, context.config.providers[error.provider] ?? context.router.resolve('workhorse').provider, role: 'workhorse', localOnly: context.router.localOnly)} The result above stands.',
        );
      }
    }
  }

  if (json) {
    context.out.writeln(
      jsonEncode(envelope(result: result, explanation: explanation)),
    );
    return 0;
  }

  // The next step is offered, never taken automatically.
  say('');
  if (yes) {
    say('Restore to before this turn? [y/N] yes (--yes)');
  } else {
    context.out.write('Restore to before this turn? [y/N] ');
    final answer = (context.readLine() ?? '').trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      say('Not restored. You can run: doc restore ${bad.id}');
      return 0;
    }
  }
  return restoreCheckpoint(context, bad.id);
}

Future<ProbeRecord> _probe(
  DocContext context,
  DmcClient dmc, {
  required String root,
  required BisectPoint point,
  required int index,
  required String directory,
  required String? setup,
  required String test,
  required List<String> links,
  required Duration timeout,
  required bool keep,
}) async {
  final stopwatch = Stopwatch()..start();
  final exported = await dmc.runJson([
    'checkpoint',
    'export',
    point.checkpoint.id,
    '--state',
    point.state,
    '--to',
    directory,
  ], workspace: context.workspace);
  if (exported['ok'] != true) {
    final errors = (exported['errors'] as List? ?? const [])
        .whereType<Map>()
        .map((error) => '${error['code']}: ${error['message']}')
        .join('; ');
    throw _BisectAbort('dmc could not export ${point.description}: $errors');
  }
  try {
    linkDependencies(root, directory, links);
    var setupFailed = false;
    final output = StringBuffer();
    if (setup != null && setup.isNotEmpty) {
      final run = await runShell(setup, directory, timeout, context.env);
      output.write(run.output);
      if (run.exitCode != 0 || run.timedOut) setupFailed = true;
    }
    var passed = false;
    var timedOut = false;
    if (!setupFailed) {
      final run = await runShell(test, directory, timeout, context.env);
      output.write(run.output);
      timedOut = run.timedOut;
      passed = run.exitCode == 0 && !run.timedOut;
      if (run.timedOut) {
        output.writeln('(timed out after ${timeout.inSeconds} s)');
      }
    }
    return ProbeRecord(
      index: index,
      point: point,
      passed: passed,
      timedOut: timedOut,
      setupFailed: setupFailed,
      elapsed: stopwatch.elapsed,
      outputTail: tailLines(output.toString(), bisectOutputTailLines),
    );
  } finally {
    if (!keep) {
      try {
        Directory(directory).deleteSync(recursive: true);
      } on FileSystemException {
        // The whole temporary root is removed at the end.
      }
    }
  }
}
