import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'cli.dart';
import 'dmc_client.dart';
import 'lesson_commands.dart';
import 'lessons.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'probe_runner.dart';
import 'timelines.dart';

/// Room for Wonder's reasoning plus N short plans.
const int timelinePlannerMaxTokens = 4000;

/// What `doc timelines` uses that tests replace.
class TimelineDeps {
  /// Ctrl-C. Defaults to SIGINT.
  final Stream<void>? interrupts;

  /// How often a status line is printed for running agents.
  final Duration statusEvery;

  /// Replaces `--timeout` for the agents (tests use seconds).
  final Duration? agentTimeout;

  const TimelineDeps({
    this.interrupts,
    this.statusEvery = const Duration(seconds: 30),
    this.agentTimeout,
  });
}

/// Who commits on timeline branches.
const List<String> _gitIdentity = [
  '-c',
  'user.name=Doc timelines',
  '-c',
  'user.email=doc-timelines@localhost',
  '-c',
  'commit.gpgsign=false',
];

class _Abort implements Exception {
  final String message;
  final int code;
  const _Abort(this.message, [this.code = 1]);
}

/// The environment for git, without variables that would point it at
/// another repository.
Map<String, String> _gitEnv(Map<String, String> env) => {
  for (final entry in env.entries)
    if (!const {
      'GIT_DIR',
      'GIT_WORK_TREE',
      'GIT_INDEX_FILE',
      'GIT_OBJECT_DIRECTORY',
      'GIT_COMMON_DIR',
    }.contains(entry.key))
      entry.key: entry.value,
};

Future<String> _git(
  DocContext context,
  String directory,
  List<String> args, {
  bool allowFailure = false,
}) async {
  final result = await Process.run(
    'git',
    ['-C', directory, ...args],
    environment: _gitEnv(context.env),
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (result.exitCode != 0 && !allowFailure) {
    throw _Abort(
      'git ${args.first} failed in $directory: ${'${result.stderr}'.trim()}',
    );
  }
  return '${result.stdout}';
}

String _timelinesRoot(DocContext context) =>
    p.join(docDataDirectory(context.env), 'timelines');

File _runFile(DocContext context, String id) =>
    File(p.join(_timelinesRoot(context), id, 'run.json'));

void _save(DocContext context, TimelineRun run) {
  final file = _runFile(context, run.id);
  file.parent.createSync(recursive: true);
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(run.toJson())}\n',
  );
  temporary.renameSync(file.path);
}

TimelineRun _load(DocContext context, String id) {
  final file = _runFile(context, id);
  if (!file.existsSync()) {
    throw _Abort('No timelines run $id (looked in ${file.parent.path}).', 2);
  }
  return TimelineRun.fromJson(jsonDecode(file.readAsStringSync()) as Map);
}

/// `doc timelines "<task>" --test "<command>" …`, `doc timelines list`,
/// `show <run-id>`, `pick <run-id> <k>` and `clean <run-id>`.
Future<int> runTimelinesCommand(DocContext context, TimelineDeps deps) async {
  final rest = context.args.rest;
  try {
    if (rest.length >= 2) {
      switch (rest[1]) {
        case 'list':
          return _list(context);
        case 'show':
          return _show(context);
        case 'pick':
          return await _pick(context);
        case 'clean':
          return await _clean(context);
      }
    }
    return await _run(context, deps);
  } on _Abort catch (error) {
    context.log(error.message);
    return error.code;
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
}

const String _usage =
    'Usage: doc timelines "<task>" --test "<command>" [--from <checkpoint> --state before|after] [--n 3] [--setup "<command>"] [--link <dir>]... [--max-steps <n>] [--timeout <minutes>] [--yes] [--json]\n'
    '       doc timelines list | show <run-id> | pick <run-id> <k> | clean <run-id>';

Future<int> _run(DocContext context, TimelineDeps deps) async {
  final args = context.args;
  final json = args['json'] as bool;
  final yes = args['yes'] as bool;
  void say(String line) => json ? context.log(line) : context.out.writeln(line);
  final task = context.args.rest.skip(1).join(' ').trim();
  final test = (args['test'] as String?)?.trim();
  if (task.isEmpty || test == null || test.isEmpty) {
    context.log(_usage);
    return 2;
  }
  int option(String name, int fallback, int low, int high) {
    final text = args[name] as String?;
    final value = text == null ? fallback : int.tryParse(text);
    if (value == null || value < low || value > high) {
      throw _Abort('--$name takes a number from $low to $high.', 2);
    }
    return value;
  }

  final n = option('n', 3, 2, 5);
  final maxSteps = option('max-steps', 20, 1, 200);
  final timeoutMinutes = option('timeout', 10, 1, 120);
  final state = (args['state'] as String?) ?? 'after';
  if (state != 'before' && state != 'after') {
    throw const _Abort('--state takes before or after.', 2);
  }
  if (context.router.localOnly) {
    throw const _Abort(
      '--local refuses doc timelines: planning uses Muse Wonder on Meta and the agents are Muse Code, both hosted. Nothing was planned or started.',
    );
  }
  final setup = (args['setup'] as String?)?.trim();
  final links = args['link'] as List<String>;

  // 1. The base state, from dmc only.
  final dmc = await context.dmc();
  final listed = await dmc.runJson([
    'checkpoint',
    'list',
    '--limit',
    '1000',
  ], workspace: context.workspace);
  if (listed['ok'] != true) {
    throw _Abort('dmc checkpoint list failed: ${listed['errors']}');
  }
  final workspace = listed['workspace'] as Map;
  final root = workspace['path'] as String;
  final fingerprint = workspace['fingerprint'] as String;
  final items = ((listed['data'] as Map)['checkpoints'] as List)
      .whereType<Map>()
      .toList();
  final from = args['from'] as String?;
  final Map baseItem;
  if (from == null) {
    final closed = items.where((c) => c['status'] == 'closed').toList()
      ..sort(
        (a, b) => (b['createdAt'] as num).compareTo(a['createdAt'] as num),
      );
    if (closed.isEmpty) {
      throw const _Abort('There is no closed checkpoint to start from.');
    }
    baseItem = closed.first;
  } else {
    baseItem = items.firstWhere(
      (c) => c['id'] == from,
      orElse: () =>
          throw _Abort('--from $from is not a checkpoint in $root.', 2),
    );
    if (baseItem['status'] != 'closed') {
      throw _Abort(
        '--from $from is ${baseItem['status']}; only a closed checkpoint can be a base.',
      );
    }
  }
  final baseId = baseItem['id'] as String;
  final baseLabel = baseItem['label'] as String?;
  final show = await dmc.runJson([
    'checkpoint',
    'show',
    baseId,
  ], workspace: context.workspace);
  final baseChanged = [
    for (final f
        in ((show['data'] as Map?)?['files'] as List? ?? const [])
            .whereType<Map>())
      if (f['change'] != null && f['change'] != 'unchanged')
        '${f['path']} (${f['change']})',
  ];

  // The repository: a Git work tree whose top is dmc's workspace root.
  final top = (await _git(context, root, [
    'rev-parse',
    '--show-toplevel',
  ], allowFailure: true)).trim();
  if (top.isEmpty ||
      !p.equals(
        Directory(top).resolveSymbolicLinksSync(),
        Directory(root).resolveSymbolicLinksSync(),
      )) {
    throw _Abort(
      'doc timelines needs the dmc workspace to be the top of a Git work tree (worktrees are Git worktrees); $root is ${top.isEmpty ? 'not in Git' : 'inside $top'}.',
    );
  }
  final head = (await _git(context, root, [
    'rev-parse',
    '--verify',
    'HEAD',
  ], allowFailure: true)).trim();
  if (head.isEmpty) {
    throw const _Abort(
      'The repository has no commit yet; a timeline worktree starts from one. Commit once, then try again.',
    );
  }

  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final runId =
      'tl-${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}-${Random().nextInt(0xffff).toRadixString(16).padLeft(4, '0')}';
  final runDir = p.join(_timelinesRoot(context), runId);
  if (p.isWithin(root, runDir) || p.equals(root, runDir)) {
    throw _Abort(
      'Doc\'s data dir is inside the repository ($runDir); timeline worktrees must be outside it. Set DOC_DATA_DIR.',
    );
  }
  Directory(runDir).createSync(recursive: true);
  final exportDir = p.join(runDir, 'base');
  final exported = await dmc.runJson([
    'checkpoint', 'export', baseId, '--state', state, '--to', exportDir, //
  ], workspace: context.workspace);
  if (exported['ok'] != true) {
    throw _Abort(
      'dmc could not export $baseId ($state): ${exported['errors']}',
    );
  }
  final exportFiles = <String>{
    for (final entity in Directory(
      exportDir,
    ).listSync(recursive: true, followLinks: false))
      if (entity is File)
        p.posix.joinAll(p.split(p.relative(entity.path, from: exportDir))),
  };
  final baseDescription =
      '$state state of checkpoint $baseId (${(baseItem['agent'] as Map?)?['name'] ?? baseItem['source']})';
  say('Base: $baseDescription: ${baseLabel ?? '(no label)'}');
  say('  ${exportFiles.length} file(s), exported by dmc to $exportDir');

  // 2. Lessons and the plan.
  String? brief;
  final briefResult = await buildBrief(context, task);
  if (briefResult?.brief != null) {
    brief = briefResult!.brief;
    say('Lesson brief (${briefResult.footer}): $brief');
  } else if (briefResult != null && briefResult.matches.isEmpty) {
    say('No lessons match this task.');
  }
  final messages = [
    const ChatMessage('system', timelinePlannerSystemPrompt),
    ChatMessage(
      'user',
      timelinePlannerMessage(
        task: task,
        n: n,
        brief: brief,
        baseDescription: baseDescription,
        baseLabel: baseLabel,
        baseChanged: baseChanged,
        files: exportFiles.toList()..sort(),
        test: test,
      ),
    ),
  ];
  final format = timelineApproachesFormat(n);
  if (args['show-prompt'] as bool) {
    final prepared = context.router.prepare(
      'planner',
      messages,
      maxTokens: timelinePlannerMaxTokens,
      responseFormat: format,
    );
    say(
      'Would send to ${prepared.route.provider.id} (${prepared.route.model}). Nothing was sent.',
    );
    say('Redacted: ${prepared.redactionCount} item(s)');
    context.out.writeln(
      const JsonEncoder.withIndent('  ').convert(prepared.body),
    );
    Directory(runDir).deleteSync(recursive: true);
    return 0;
  }
  List<TimelineApproach>? approaches;
  String? problem;
  var sent = messages;
  RoleCallResult? call;
  var plannerCost = 0.0;
  var plannerIn = 0;
  var plannerOut = 0;
  for (var attempt = 1; attempt <= 2 && approaches == null; attempt++) {
    try {
      call = await context.router.call(
        'planner',
        sent,
        maxTokens: timelinePlannerMaxTokens,
        responseFormat: format,
      );
    } on ModelCallException catch (error) {
      Directory(runDir).deleteSync(recursive: true);
      throw _Abort(
        'Planning failed: ${explainFailure(error, context.config.providers[error.provider] ?? context.router.resolve('planner').provider, role: 'planner')} Nothing was started.',
      );
    }
    plannerCost += call.costUsd;
    plannerIn += call.result.promptTokens;
    plannerOut += call.result.completionTokens;
    try {
      approaches = parseTimelineApproaches(
        call.result.content,
        n,
        files: exportFiles,
      );
    } on TimelinePlanRefused catch (error) {
      problem = error.message;
      if (attempt == 1) {
        context.log('The plan could not be used ($problem) Asking once more.');
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
  if (approaches == null) {
    Directory(runDir).deleteSync(recursive: true);
    throw _Abort('Doc refused the plan: $problem Nothing was started.');
  }
  final planner = {
    'provider': call!.result.provider,
    'model': call.result.model,
    'promptTokens': plannerIn,
    'completionTokens': plannerOut,
    'costUsd': plannerCost,
    'redactionCount': call.redactionCount,
  };
  say('');
  say(
    'Plan (${call.result.provider} ${call.result.model}; $plannerIn in / $plannerOut out; \$${plannerCost.toStringAsFixed(4)}; ${call.redactionCount} item(s) redacted):',
  );
  for (var i = 0; i < approaches.length; i++) {
    final a = approaches[i];
    say('  ${i + 1}. ${a.title}');
    say('     ${a.plan}');
    if (a.filesLikely.isNotEmpty) {
      say('     files: ${a.filesLikely.join(', ')}');
    }
  }

  final run = TimelineRun(
    id: runId,
    createdAt: now.toUtc().toIso8601String(),
    task: task,
    test: test,
    setup: setup,
    links: links,
    maxSteps: maxSteps,
    timeoutMinutes: timeoutMinutes,
    repo: root,
    workspaceFingerprint: fingerprint,
    baseCheckpoint: baseId,
    baseState: state,
    baseLabel: baseLabel,
    baseCommit: null,
    brief: brief,
    planner: planner,
    timelines: [
      for (var k = 1; k <= n; k++)
        Timeline(
          k: k,
          approach: approaches[k - 1],
          branch: 'doc/timeline/$runId/$k',
          worktree: p.join(runDir, '$k'),
        ),
    ],
  );
  _save(context, run);

  // 3. Confirm, with an honest estimate.
  final hooks = await Process.run(dmc.executable, [
    'hooks',
    'status',
    '--agent',
    'muse-code',
  ], workingDirectory: root);
  final hooksOn = hooks.exitCode == 0;
  final estimate = estimateTimelineCost(n, maxSteps);
  say('');
  say(
    'Estimate: at most \$${estimate.contributor.toStringAsFixed(2)} in Contributor mode (muse-spark-1.3-contributor, what Muse Code used on this Mac) '
    'or \$${estimate.standard.toStringAsFixed(2)} in Standard mode: $n agent(s) × $maxSteps step(s) × ~${museInputTokensPerStep ~/ 1000}k input + $museOutputTokensPerStep output tokens per step '
    '(measured with muse exec 1.4.14), with no cache discount. Muse Code bills its own Meta account; Doc reads the real tokens afterwards.',
  );
  if (!hooksOn) {
    say(
      'Muse Code\'s user-scope dmc hooks are not installed (dmc hooks status --agent muse-code), so the timelines run without per-turn checkpoints.',
    );
  }
  final question =
      'Run $n Muse Code agents in separate worktrees (max $maxSteps steps, $timeoutMinutes min each, est. cost ≤ \$${estimate.contributor.toStringAsFixed(2)}–\$${estimate.standard.toStringAsFixed(2)})? [y/N] ';
  bool agreed;
  if (yes) {
    say('${question}yes (--yes)');
    agreed = true;
  } else {
    if (json) {
      context.log(question.trimRight());
    } else {
      context.out.write(question);
    }
    final answer = (context.readLine() ?? '').trim().toLowerCase();
    agreed = answer == 'y' || answer == 'yes';
  }
  if (!agreed) {
    run.status = 'declined';
    _save(context, run);
    Directory(exportDir).deleteSync(recursive: true);
    say('Nothing was started. The plan is saved as $runId.');
    if (json) context.out.writeln(jsonEncode(run.toJson()));
    return 0;
  }

  // 4. Worktrees outside the repository, each holding exactly the base.
  final first = run.timelines.first;
  await _git(context, root, [
    'worktree',
    'add',
    first.worktree,
    '-b',
    first.branch,
    'HEAD',
  ]);
  final present = (await _git(context, first.worktree, [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
    '-z',
  ])).split('\u0000').where((path) => path.isNotEmpty).toSet();
  for (final action in treeSyncActions(exportFiles, present)) {
    final target = File(p.joinAll([first.worktree, ...action.path.split('/')]));
    if (action.kind == 'delete') {
      if (target.existsSync()) target.deleteSync();
    } else {
      target.parent.createSync(recursive: true);
      File(
        p.joinAll([exportDir, ...action.path.split('/')]),
      ).copySync(target.path);
    }
  }
  await _git(context, first.worktree, ['add', '-A']);
  await _git(context, first.worktree, [
    ..._gitIdentity,
    'commit',
    '--allow-empty',
    '-q',
    '-m',
    'timeline base: $baseId $state',
  ]);
  final baseCommit = (await _git(context, first.worktree, [
    'rev-parse',
    'HEAD',
  ])).trim();
  for (final t in run.timelines.skip(1)) {
    await _git(context, root, [
      'worktree',
      'add',
      t.worktree,
      '-b',
      t.branch,
      baseCommit,
    ]);
  }
  Directory(exportDir).deleteSync(recursive: true);
  run.baseCommit = baseCommit;
  final active = run;
  for (final t in active.timelines) {
    final init = await Process.run(dmc.executable, [
      'init',
    ], workingDirectory: t.worktree);
    if (init.exitCode != 0) {
      throw _Abort('dmc init failed in ${t.worktree}: ${init.stderr}');
    }
  }
  say('');
  say(
    'Worktrees (base commit ${baseCommit.substring(0, 12)}, "timeline base: $baseId $state"), each with its own dmc vault:',
  );
  for (final t in active.timelines) {
    say('  ${t.k}. ${t.worktree}  (${t.branch})');
  }

  // 5–6. Agents in parallel, then each one's tests.
  active.status = 'running';
  _save(context, active);
  final muse = context.env['DOC_MUSE_BIN'] ?? 'muse';
  final processes = <int, Process>{};
  var interrupted = false;
  final clock = Stopwatch()..start();
  StreamSubscription<void>? interrupt;
  Stream<void>? interrupts = deps.interrupts;
  if (interrupts == null) {
    try {
      interrupts = ProcessSignal.sigint.watch();
    } on SignalException {
      interrupts = null;
    }
  }
  final allStopped = Completer<void>();
  interrupt = interrupts?.listen((_) {
    if (interrupted) return;
    interrupted = true;
    context.log(
      'Interrupted: stopping all agents. The worktrees and branches are kept.',
    );
    for (final process in processes.values) {
      process.kill(ProcessSignal.sigterm);
    }
    if (!allStopped.isCompleted) allStopped.complete();
  });
  String clockText(double seconds) {
    final s = seconds.round();
    return '${s ~/ 60}:${two(s % 60)}';
  }

  final status = Timer.periodic(deps.statusEvery, (_) {
    final running = active.timelines.where(
      (t) => t.status == TimelineStatus.running,
    );
    if (running.isEmpty) return;
    say(
      '  … running: ${running.map((t) => '[${t.k}]').join(' ')} (${clockText(clock.elapsedMilliseconds / 1000)})',
    );
  });

  Future<void> runAgentAndTests(Timeline t) async {
    if (interrupted) {
      t.status = TimelineStatus.stopped;
      t.reason = 'stopped by Ctrl-C before it started';
      return;
    }
    final lesson = brief;
    final prompt = [
      ?lesson,
      'Approach ${t.k} of $n: ${t.approach.title}\n${t.approach.plan}',
      'Task: $task',
      'Work only in this folder. When you are done, Doc runs the tests here with: $test',
    ].join('\n\n');
    final watch = Stopwatch()..start();
    t.status = TimelineStatus.running;
    say('[timeline ${t.k}] running: ${t.approach.title}');
    final events = File(p.join(runDir, '${t.k}.jsonl')).openWrite();
    final log = File(p.join(runDir, '${t.k}.log')).openWrite();
    Process? process;
    try {
      process = await Process.start(
        muse,
        [
          'exec',
          prompt,
          '--max-model-steps',
          '$maxSteps',
          '--disable-web-tools',
          '--json',
        ],
        workingDirectory: t.worktree,
        environment: context.env,
        includeParentEnvironment: false,
      );
    } on ProcessException catch (error) {
      t.status = TimelineStatus.failed;
      t.reason = 'could not start $muse: ${error.message}';
      say('[timeline ${t.k}] failed: ${t.reason}');
      await events.close();
      await log.close();
      return;
    }
    processes[t.k] = process;
    if (interrupted) process.kill(ProcessSignal.sigterm);
    final lines = <String>[];
    final reading = Future.wait([
      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach((line) {
            lines.add(line);
            events.writeln(line);
          }),
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .forEach(log.write),
    ]);
    var timedOut = false;
    final code = await process.exitCode.timeout(
      deps.agentTimeout ?? Duration(minutes: timeoutMinutes),
      onTimeout: () async {
        timedOut = true;
        process!.kill(ProcessSignal.sigterm);
        return await process.exitCode.timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            process!.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      },
    );
    await reading.timeout(
      const Duration(seconds: 5),
      onTimeout: () => const [],
    );
    await events.close();
    await log.close();
    processes.remove(t.k);
    final outcome = parseMuseEvents(lines);
    t
      ..seconds = watch.elapsedMilliseconds / 1000
      ..steps = outcome.steps
      ..inputTokens = outcome.inputTokens
      ..cachedTokens = outcome.cachedTokens
      ..outputTokens = outcome.outputTokens
      ..model = outcome.model
      ..costUsd = museCostUsd(outcome);
    if (interrupted) {
      t.status = TimelineStatus.stopped;
      t.reason = 'stopped by Ctrl-C';
    } else if (timedOut) {
      t.status = TimelineStatus.timedOut;
      t.reason = 'no result within $timeoutMinutes min';
    } else if (code == 0 && outcome.terminal != 'failed') {
      t.status = TimelineStatus.done;
    } else {
      t.status = TimelineStatus.failed;
      t.reason = outcome.reason ?? 'muse exited $code';
    }
    say(
      '[timeline ${t.k}] ${switch (t.status) {
        TimelineStatus.done => 'done',
        TimelineStatus.timedOut => 'timed out',
        TimelineStatus.stopped => 'stopped',
        _ => outcome.stepLimit ? 'stopped at the step limit' : 'failed',
      }} after ${clockText(t.seconds)}, ${t.steps} step(s)${t.costUsd == null ? '' : ', \$${t.costUsd!.toStringAsFixed(4)}'}${t.reason == null ? '' : ' (${t.reason})'}',
    );

    // The agent's result, committed so the diff is reviewable.
    await _git(context, t.worktree, ['add', '-A']);
    await _git(context, t.worktree, [
      ..._gitIdentity,
      'commit',
      '--allow-empty',
      '-q',
      '-m',
      'timeline ${t.k}: ${t.approach.title}',
    ]);
    t.commit = (await _git(context, t.worktree, ['rev-parse', 'HEAD'])).trim();
    t.files = parseNumstat(
      await _git(context, t.worktree, [
        'diff',
        '--numstat',
        baseCommit,
        t.commit!,
      ]),
    );
    final listedHere = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '1000',
    ], workspace: t.worktree);
    t.checkpoints =
        (((listedHere['data'] as Map?)?['checkpoints'] as List?) ?? const [])
            .whereType<Map>()
            .where((c) => c['agent'] is Map)
            .length;
    _save(context, active);
    if (interrupted) return;

    // Tests, with bisect's runner, in the worktree.
    final testClock = Stopwatch()..start();
    final made = linkDependencies(root, t.worktree, links);
    final output = StringBuffer();
    var setupFailed = false;
    var testTimedOut = false;
    var passed = false;
    try {
      final probeTimeout = Duration(minutes: timeoutMinutes);
      if (setup != null && setup.isNotEmpty) {
        final ran = await runShell(
          setup,
          t.worktree,
          probeTimeout,
          context.env,
        );
        output.write(ran.output);
        setupFailed = !ran.passed;
      }
      if (!setupFailed) {
        final ran = await runShell(test, t.worktree, probeTimeout, context.env);
        output.write(ran.output);
        testTimedOut = ran.timedOut;
        passed = ran.passed;
      }
    } finally {
      for (final link in made) {
        try {
          Link(link).deleteSync();
        } on FileSystemException {
          // Best effort; never follows the link.
        }
      }
    }
    t.test = TimelineTest(
      passed: passed,
      timedOut: testTimedOut,
      setupFailed: setupFailed,
      seconds: testClock.elapsedMilliseconds / 1000,
      tail: tailLines(output.toString(), 40),
    );
    say(
      '[timeline ${t.k}] tests ${passed ? 'PASS' : 'FAIL'} (${t.test!.seconds.toStringAsFixed(1)}s)',
    );
    _save(context, active);
  }

  Future<void> runOne(Timeline t) async {
    try {
      await runAgentAndTests(t);
    } on Object catch (error) {
      // One timeline's failure never stops the others.
      t.status = t.status == TimelineStatus.running
          ? TimelineStatus.failed
          : t.status;
      t.reason ??= '$error';
      say('[timeline ${t.k}] error: $error');
      _save(context, active);
    }
  }

  final all = Future.wait([for (final t in active.timelines) runOne(t)]);
  await Future.any([all, allStopped.future]);
  if (interrupted) {
    // Every agent was killed; let each record its stop (no tests run).
    await all.timeout(const Duration(seconds: 30), onTimeout: () => const []);
  }
  status.cancel();
  await interrupt?.cancel();
  active
    ..status = interrupted ? 'interrupted' : 'done'
    ..seconds = clock.elapsedMilliseconds / 1000;
  _save(context, active);

  // 7. Compare.
  say('');
  say(
    'Run $runId (${clockText(active.seconds)} wall time). Base: $baseId $state.',
  );
  for (final line in timelineComparison(active)) {
    say(line);
  }
  final spent = active.timelines.fold<double>(
    0,
    (sum, t) => sum + (t.costUsd ?? 0),
  );
  say(
    'Muse Code: \$${spent.toStringAsFixed(4)} (from each run\'s reported tokens); planner: \$${plannerCost.toStringAsFixed(4)}.',
  );
  say(
    interrupted
        ? 'Stopped. Worktrees and branches are kept: doc timelines show $runId.'
        : 'Pick one with: doc timelines pick $runId <k>. Nothing is merged for you; unpicked timelines stay as branches.',
  );
  if (json) context.out.writeln(jsonEncode(active.toJson()));
  return interrupted ? 130 : 0;
}

List<TimelineRun> _runs(DocContext context) {
  final root = Directory(_timelinesRoot(context));
  if (!root.existsSync()) return [];
  final runs = <TimelineRun>[];
  for (final entity in root.listSync()) {
    final file = File(p.join(entity.path, 'run.json'));
    if (entity is Directory && file.existsSync()) {
      try {
        runs.add(
          TimelineRun.fromJson(jsonDecode(file.readAsStringSync()) as Map),
        );
      } on Object {
        // Skip a damaged run file.
      }
    }
  }
  runs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return runs;
}

int _list(DocContext context) {
  final runs = _runs(context);
  if (context.args['json'] as bool) {
    context.out.writeln(jsonEncode([for (final r in runs) r.toJson()]));
    return 0;
  }
  if (runs.isEmpty) {
    context.out.writeln('No timelines runs yet.');
    return 0;
  }
  for (final run in runs) {
    final passed = run.timelines.where((t) => t.test?.passed ?? false).length;
    context.out.writeln(
      '${run.id}  ${run.status}  ${run.timelines.length} timeline(s), $passed passing${run.picked == null ? '' : ', picked ${run.picked}'}  ${run.repo}  ${run.task}',
    );
  }
  return 0;
}

int _show(DocContext context) {
  final rest = context.args.rest;
  if (rest.length != 3) {
    throw const _Abort('Usage: doc timelines show <run-id>', 2);
  }
  final run = _load(context, rest[2]);
  if (context.args['json'] as bool) {
    context.out.writeln(jsonEncode(run.toJson()));
    return 0;
  }
  context.out
    ..writeln('Run ${run.id} (${run.status}), ${run.createdAt}')
    ..writeln('Task: ${run.task}')
    ..writeln('Tests: ${run.test}')
    ..writeln(
      'Base: ${run.baseCheckpoint} ${run.baseState} (commit ${run.baseCommit ?? 'none'})',
    );
  for (final line in timelineComparison(run)) {
    context.out.writeln(line);
  }
  return 0;
}

Future<int> _pick(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 4) {
    throw const _Abort('Usage: doc timelines pick <run-id> <k>', 2);
  }
  final run = _load(context, rest[2]);
  final k = int.tryParse(rest[3]);
  final timeline = run.timelines.where((t) => t.k == k).firstOrNull;
  if (timeline == null || timeline.commit == null || run.baseCommit == null) {
    throw _Abort('Run ${run.id} has no finished timeline ${rest[3]}.', 2);
  }
  // Read-only: git diff, from the worktree when it still exists.
  final where = Directory(timeline.worktree).existsSync()
      ? timeline.worktree
      : run.repo;
  final diff = await _git(context, where, [
    'diff',
    '--stat',
    '--patch',
    run.baseCommit!,
    timeline.branch,
  ]);
  final out = context.out;
  out
    ..writeln('Timeline ${timeline.k} of ${run.id}: ${timeline.approach.title}')
    ..writeln(
      'Tests: ${timeline.test == null
          ? 'not run'
          : timeline.test!.passed
          ? 'PASS'
          : 'FAIL'}; branch ${timeline.branch}; ${timeline.files.length} file(s) changed against the base.',
    )
    ..writeln('')
    ..writeln(
      'Diff against the base (${run.baseCheckpoint} ${run.baseState}, commit ${run.baseCommit!.substring(0, 12)}):',
    )
    ..writeln(diff.trimRight())
    ..writeln('')
    ..writeln(
      'Doc changes nothing in your repository. To bring this timeline in, in ${run.repo}:',
    )
    ..writeln(
      '  git status                    # commit or stash your own changes first',
    )
    ..writeln('  # Only the timeline\'s change, onto your working copy:')
    ..writeln(
      '  git diff ${run.baseCommit!.substring(0, 12)} ${timeline.branch} > /tmp/${run.id}-${timeline.k}.patch',
    )
    ..writeln('  git apply --3way /tmp/${run.id}-${timeline.k}.patch')
    ..writeln(
      '  # Or merge the branch (this also brings the "timeline base" commit, which sets the files to the base state):',
    )
    ..writeln('  git merge --no-ff ${timeline.branch}')
    ..writeln(
      'If your working copy is past the base (later agent turns), first go back with doc restore ${run.baseCheckpoint} (dmc previews it and asks), or apply the patch and resolve.',
    );
  final others = run.timelines
      .where((t) => t.k != timeline.k)
      .map((t) => t.branch);
  if (others.isNotEmpty) {
    out.writeln(
      'The other timelines are archived as branches (never deleted): ${others.join(', ')}',
    );
  }
  run.picked = timeline.k;
  _save(context, run);
  return 0;
}

Future<int> _clean(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3) {
    throw const _Abort('Usage: doc timelines clean <run-id> [--yes]', 2);
  }
  final run = _load(context, rest[2]);
  final present = [
    for (final t in run.timelines)
      if (Directory(t.worktree).existsSync()) t,
  ];
  if (present.isEmpty) {
    context.out.writeln(
      'Run ${run.id} has no worktree folders left. Its branches stay.',
    );
    return 0;
  }
  final question =
      'Remove ${present.length} worktree folder(s) of ${run.id}? The branches (${run.timelines.map((t) => t.branch).join(', ')}) are kept. [y/N] ';
  if (context.args['yes'] as bool) {
    context.out.writeln('${question}yes (--yes)');
  } else {
    context.out.write(question);
    final answer = (context.readLine() ?? '').trim().toLowerCase();
    if (answer != 'y' && answer != 'yes') {
      context.out.writeln('Nothing was removed.');
      return 0;
    }
  }
  for (final t in present) {
    // --force: test output and the worktree's .dmc vault are not committed.
    await _git(context, run.repo, [
      'worktree',
      'remove',
      '--force',
      t.worktree,
    ]);
    context.out.writeln('Removed ${t.worktree} (branch ${t.branch} kept).');
  }
  await _git(context, run.repo, ['worktree', 'prune'], allowFailure: true);
  run.status = 'cleaned';
  _save(context, run);
  return 0;
}
