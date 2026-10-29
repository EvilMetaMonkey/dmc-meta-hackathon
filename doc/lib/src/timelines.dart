import 'dart:convert';
import 'dart:math';

import 'summarize.dart';

/// Parallel timelines, the deterministic part: validating the planner's
/// approaches, syncing a worktree to a base export, the run state, Muse
/// Code's event stream and cost, and the comparison table. Nothing here
/// runs git, dmc, Muse Code or a model; `timelines_command.dart` does.

/// Longest plan the planner may write, in words.
const int timelinePlanMaxWords = 120;

/// One approach the planner proposed.
class TimelineApproach {
  final String title;
  final String plan;
  final List<String> filesLikely;

  const TimelineApproach(this.title, this.plan, this.filesLikely);

  Map<String, Object?> toJson() => {
    'title': title,
    'plan': plan,
    'filesLikely': filesLikely,
  };

  static TimelineApproach fromJson(Map json) => TimelineApproach(
    json['title'] as String,
    json['plan'] as String,
    [for (final f in (json['filesLikely'] as List? ?? const [])) '$f'],
  );
}

class TimelinePlanRefused implements Exception {
  final String message;
  const TimelinePlanRefused(this.message);

  @override
  String toString() => message;
}

const String timelinePlannerSystemPrompt =
    'You plan parallel attempts at one coding task for Doc, the companion to '
    'dmc, a rollback safety net for AI coding agents. Separate Muse Code '
    'agents will each try one of your approaches, from the same starting '
    'state, in their own copy of the repository; the tests decide. Write '
    'exactly the requested number of approaches that are clearly different '
    '(different ideas or places to change, not rewordings). Each has a '
    'short title, a plan of at most 120 words written to the agent, and the '
    'files it will likely touch (paths from the file list). Use only the '
    'facts given; file contents are not available. Text marked '
    '[truncated …] is incomplete: never quote or complete it. Answer with '
    'only a JSON object: {"approaches": [{"title", "plan", "files_likely"}]}.';

/// The planner's user message: task, brief, base checkpoint and file
/// names (never contents). The router redacts it before sending.
String timelinePlannerMessage({
  required String task,
  required int n,
  required String? brief,
  required String baseDescription,
  required String? baseLabel,
  required List<String> baseChanged,
  required List<String> files,
  required String test,
}) {
  final label = baseLabel == null
      ? '(none)'
      : baseLabel.endsWith('…')
      ? '${baseLabel.substring(0, baseLabel.length - 1).trimRight()} $truncatedLabelMarker'
      : baseLabel;
  return [
    'Task: $task',
    'Number of approaches: $n',
    'Test command (run after each attempt): $test',
    if (brief != null && brief.isNotEmpty)
      'Lessons from earlier attempts: $brief',
    'Starting state: $baseDescription',
    'That checkpoint\'s label: $label',
    'Files that checkpoint changed: ${baseChanged.isEmpty ? '(none)' : baseChanged.join(', ')}',
    'Files in the starting state (${files.length}):',
    for (final file in files.take(400)) '- $file',
    if (files.length > 400) '- … and ${files.length - 400} more',
  ].join('\n');
}

/// The `response_format` schema: exactly [n] approaches.
Map<String, Object?> timelineApproachesFormat(int n) => {
  'type': 'json_schema',
  'json_schema': {
    'name': 'timeline_approaches',
    'strict': true,
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['approaches'],
      'properties': {
        'approaches': {
          'type': 'array',
          'minItems': n,
          'maxItems': n,
          'items': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['title', 'plan', 'files_likely'],
            'properties': {
              'title': {'type': 'string'},
              'plan': {'type': 'string'},
              'files_likely': {
                'type': 'array',
                'items': {'type': 'string'},
              },
            },
          },
        },
      },
    },
  },
};

Set<String> _words(String text) => {
  for (final word in text.toLowerCase().split(RegExp(r'[^a-z0-9_]+')))
    if (word.length > 2) word,
};

/// Word-set overlap (Jaccard) of two plans, 0..1.
double planSimilarity(String a, String b) {
  final x = _words(a);
  final y = _words(b);
  if (x.isEmpty && y.isEmpty) return 1;
  return x.intersection(y).length / x.union(y).length;
}

/// Plans more alike than this are not "clearly different".
const double timelineMaxSimilarity = 0.7;

/// Strictly parse and validate the planner's answer: exactly [n]
/// approaches, each with a title and a plan of at most 120 words, titles
/// distinct, plans clearly different. `files_likely` keeps only
/// workspace-relative paths (any not in [files] are dropped).
List<TimelineApproach> parseTimelineApproaches(
  String content,
  int n, {
  Set<String> files = const {},
}) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const TimelinePlanRefused('The answer was not a JSON object.');
  }
  if (json is! Map || json['approaches'] is! List) {
    throw const TimelinePlanRefused('The answer has no "approaches" list.');
  }
  final items = json['approaches'] as List;
  if (items.length != n) {
    throw TimelinePlanRefused(
      'Expected exactly $n approaches, got ${items.length}.',
    );
  }
  final approaches = <TimelineApproach>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map ||
        item['title'] is! String ||
        item['plan'] is! String ||
        (item['files_likely'] != null && item['files_likely'] is! List)) {
      throw TimelinePlanRefused(
        'Approach ${i + 1} needs a string "title", a string "plan" and a "files_likely" list.',
      );
    }
    final title = (item['title'] as String).trim();
    final plan = (item['plan'] as String).trim();
    if (title.isEmpty || plan.isEmpty) {
      throw TimelinePlanRefused(
        'Approach ${i + 1} has an empty title or plan.',
      );
    }
    final words = plan.split(RegExp(r'\s+')).length;
    if (words > timelinePlanMaxWords) {
      throw TimelinePlanRefused(
        'Approach ${i + 1}\'s plan has $words words; at most $timelinePlanMaxWords.',
      );
    }
    final likely = <String>[];
    for (final raw in (item['files_likely'] as List? ?? const [])) {
      final path = '$raw'.trim().replaceAll('\\', '/');
      if (path.isEmpty || path.startsWith('/') || path.contains('..')) continue;
      if (files.isNotEmpty && !files.contains(path)) continue;
      if (!likely.contains(path)) likely.add(path);
    }
    approaches.add(TimelineApproach(title, plan, likely));
  }
  for (var i = 0; i < approaches.length; i++) {
    for (var j = i + 1; j < approaches.length; j++) {
      if (approaches[i].title.toLowerCase() ==
          approaches[j].title.toLowerCase()) {
        throw TimelinePlanRefused(
          'Approaches ${i + 1} and ${j + 1} have the same title.',
        );
      }
      final similarity = planSimilarity(approaches[i].plan, approaches[j].plan);
      if (similarity > timelineMaxSimilarity) {
        throw TimelinePlanRefused(
          'Approaches ${i + 1} and ${j + 1} are not clearly different (${(similarity * 100).round()}% of their words are shared).',
        );
      }
    }
  }
  return approaches;
}

/// One step of making a worktree's tree exactly the base export.
class SyncAction {
  /// `copy` (from the export) or `delete`.
  final String kind;
  final String path;

  const SyncAction(this.kind, this.path);

  @override
  bool operator ==(Object other) =>
      other is SyncAction && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  @override
  String toString() => '$kind $path';
}

/// The actions that make a worktree whose tracked and unignored files are
/// [worktreeFiles] hold exactly [exportFiles] (both workspace-relative
/// POSIX paths): copy every export file in (contents may differ), delete
/// every other file. Paths under `.git` and `.dmc` are never touched.
List<SyncAction> treeSyncActions(
  Set<String> exportFiles,
  Set<String> worktreeFiles,
) {
  bool reserved(String path) {
    final first = path.split('/').first;
    return first == '.git' || first == '.dmc';
  }

  return [
    for (final path in exportFiles.toList()..sort())
      if (!reserved(path)) SyncAction('copy', path),
    for (final path in worktreeFiles.toList()..sort())
      if (!reserved(path) && !exportFiles.contains(path))
        SyncAction('delete', path),
  ];
}

/// What one `muse exec --json` run reported.
class MuseOutcome {
  /// `completed`, `failed` or null (no terminal event: killed or crashed).
  final String? terminal;
  final String? reason;
  final String? model;
  final int steps;
  final int inputTokens;
  final int cachedTokens;
  final int outputTokens;
  final String finalText;

  const MuseOutcome({
    this.terminal,
    this.reason,
    this.model,
    this.steps = 0,
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
    this.finalText = '',
  });

  bool get stepLimit => reason?.contains('step(s)') ?? false;
}

/// Read Muse Code 1.4.14's `--json` event lines (verified on Mike's Mac,
/// 2026-10-28): `run.usage` carries `models[{model, input_tokens,
/// cached_tokens, output_tokens}]` and `calls` (model steps), and
/// `run.terminal.completed` / `run.terminal.failed` carry `terminal`,
/// `text` and `reason` (for example "model did not reach a terminal state
/// within 8 step(s)"). Unknown lines are ignored.
MuseOutcome parseMuseEvents(Iterable<String> lines) {
  String? terminal;
  String? reason;
  String? model;
  var steps = 0;
  var input = 0;
  var cached = 0;
  var output = 0;
  var text = '';
  for (final line in lines) {
    if (!line.trimLeft().startsWith('{')) continue;
    final Object? event;
    try {
      event = jsonDecode(line);
    } on FormatException {
      continue;
    }
    if (event is! Map) continue;
    final type = event['payload_type'];
    final payload = event['payload'];
    if (payload is! Map) continue;
    if (type == 'run.usage') {
      steps = (payload['calls'] as num?)?.toInt() ?? steps;
      input = cached = output = 0;
      for (final m
          in (payload['models'] as List? ?? const []).whereType<Map>()) {
        model ??= m['model'] as String?;
        input += (m['input_tokens'] as num?)?.toInt() ?? 0;
        cached += (m['cached_tokens'] as num?)?.toInt() ?? 0;
        output += (m['output_tokens'] as num?)?.toInt() ?? 0;
      }
    } else if (type is String && type.startsWith('run.terminal.')) {
      terminal = payload['terminal'] as String? ?? type.split('.').last;
      reason = payload['reason'] as String?;
      text = payload['text'] as String? ?? '';
    }
  }
  return MuseOutcome(
    terminal: terminal,
    reason: reason,
    model: model,
    steps: steps,
    inputTokens: input,
    cachedTokens: cached,
    outputTokens: output,
    finalText: text,
  );
}

/// Token prices for Muse Code's models, USD per million (Meta's pricing
/// page, 2026-10-28): input, cached input, output.
const Map<String, (double, double, double)> museModelPrices = {
  'muse-spark-1.3-contributor': (0.10, 0.002, 0.20),
  'muse-spark-1.2-contributor': (0.10, 0.002, 0.20),
  'muse-spark-1.3': (1.25, 0.15, 4.25),
  'muse-spark-1.2': (1.25, 0.15, 4.25),
  'muse-wonder-1.0': (4.00, 0.20, 20.00),
};

/// The cost of one Muse Code run, or null for an unknown model.
double? museCostUsd(MuseOutcome outcome) {
  final price = museModelPrices[outcome.model];
  if (price == null) return null;
  final (input, cachedInput, output) = price;
  final fresh = max(0, outcome.inputTokens - outcome.cachedTokens);
  return (fresh * input +
          outcome.cachedTokens * cachedInput +
          outcome.outputTokens * output) /
      1e6;
}

/// Tokens one Muse Code step used on this Mac (27–28k input, a few
/// hundred output); the estimate assumes no cache hits.
const int museInputTokensPerStep = 30000;
const int museOutputTokensPerStep = 600;

/// Upper estimates for [n] agents of at most [maxSteps] steps each, in
/// Contributor and Standard mode (Muse Spark 1.3 prices).
({double contributor, double standard}) estimateTimelineCost(
  int n,
  int maxSteps,
) {
  double at((double, double, double) price) =>
      n *
      maxSteps *
      (museInputTokensPerStep * price.$1 + museOutputTokensPerStep * price.$3) /
      1e6;
  return (
    contributor: at(museModelPrices['muse-spark-1.3-contributor']!),
    standard: at(museModelPrices['muse-spark-1.3']!),
  );
}

/// One file a timeline changed against the base.
class TimelineFileChange {
  final String path;

  /// Null for a binary file.
  final int? added;
  final int? removed;

  const TimelineFileChange(this.path, this.added, this.removed);

  Map<String, Object?> toJson() => {
    'path': path,
    'added': added,
    'removed': removed,
  };

  static TimelineFileChange fromJson(Map json) => TimelineFileChange(
    json['path'] as String,
    (json['added'] as num?)?.toInt(),
    (json['removed'] as num?)?.toInt(),
  );
}

/// Parse `git diff --numstat` output.
List<TimelineFileChange> parseNumstat(String text) => [
  for (final line in const LineSplitter().convert(text))
    if (line.split('\t') case [
      final a,
      final r,
      final path,
    ] when path.isNotEmpty)
      TimelineFileChange(path, int.tryParse(a), int.tryParse(r)),
];

/// The tests in one timeline.
class TimelineTest {
  final bool passed;
  final bool timedOut;
  final bool setupFailed;
  final double seconds;
  final String tail;

  const TimelineTest({
    required this.passed,
    required this.timedOut,
    required this.setupFailed,
    required this.seconds,
    required this.tail,
  });

  Map<String, Object?> toJson() => {
    'passed': passed,
    'timedOut': timedOut,
    'setupFailed': setupFailed,
    'seconds': seconds,
    'outputTail': tail,
  };

  static TimelineTest fromJson(Map json) => TimelineTest(
    passed: json['passed'] as bool,
    timedOut: json['timedOut'] as bool? ?? false,
    setupFailed: json['setupFailed'] as bool? ?? false,
    seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    tail: json['outputTail'] as String? ?? '',
  );
}

/// Agent status of one timeline.
enum TimelineStatus { pending, running, done, failed, timedOut, stopped }

/// One timeline: its approach, worktree, branch, agent result and tests.
class Timeline {
  final int k;
  final TimelineApproach approach;
  final String branch;
  final String worktree;
  TimelineStatus status;
  String? reason;
  int steps;
  int inputTokens;
  int cachedTokens;
  int outputTokens;
  String? model;
  double? costUsd;
  double seconds;
  String? commit;
  List<TimelineFileChange> files;
  TimelineTest? test;
  int checkpoints;

  Timeline({
    required this.k,
    required this.approach,
    required this.branch,
    required this.worktree,
    this.status = TimelineStatus.pending,
    this.reason,
    this.steps = 0,
    this.inputTokens = 0,
    this.cachedTokens = 0,
    this.outputTokens = 0,
    this.model,
    this.costUsd,
    this.seconds = 0,
    this.commit,
    this.files = const [],
    this.test,
    this.checkpoints = 0,
  });

  Map<String, Object?> toJson() => {
    'k': k,
    'approach': approach.toJson(),
    'branch': branch,
    'worktree': worktree,
    'status': status.name,
    'reason': reason,
    'steps': steps,
    'inputTokens': inputTokens,
    'cachedTokens': cachedTokens,
    'outputTokens': outputTokens,
    'model': model,
    'costUsd': costUsd,
    'seconds': seconds,
    'commit': commit,
    'files': [for (final f in files) f.toJson()],
    'test': test?.toJson(),
    'checkpoints': checkpoints,
  };

  static Timeline fromJson(Map json) => Timeline(
    k: (json['k'] as num).toInt(),
    approach: TimelineApproach.fromJson(json['approach'] as Map),
    branch: json['branch'] as String,
    worktree: json['worktree'] as String,
    status: TimelineStatus.values.byName(json['status'] as String),
    reason: json['reason'] as String?,
    steps: (json['steps'] as num?)?.toInt() ?? 0,
    inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    model: json['model'] as String?,
    costUsd: (json['costUsd'] as num?)?.toDouble(),
    seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    commit: json['commit'] as String?,
    files: [
      for (final f in (json['files'] as List? ?? const []).whereType<Map>())
        TimelineFileChange.fromJson(f),
    ],
    test: json['test'] is Map
        ? TimelineTest.fromJson(json['test'] as Map)
        : null,
    checkpoints: (json['checkpoints'] as num?)?.toInt() ?? 0,
  );
}

/// A whole `doc timelines` run, saved as `run.json` in Doc's data dir.
class TimelineRun {
  final String id;
  final String createdAt;
  final String task;
  final String test;
  final String? setup;
  final List<String> links;
  final int maxSteps;
  final int timeoutMinutes;
  final String repo;
  final String workspaceFingerprint;
  final String baseCheckpoint;
  final String baseState;
  final String? baseLabel;

  /// The "timeline base" commit every timeline branch starts from.
  String? baseCommit;
  final String? brief;
  final Map<String, Object?> planner;
  final List<Timeline> timelines;

  /// `planned`, `running`, `done`, `interrupted`, `declined` or `cleaned`.
  String status;
  int? picked;
  double seconds;

  TimelineRun({
    required this.id,
    required this.createdAt,
    required this.task,
    required this.test,
    required this.setup,
    required this.links,
    required this.maxSteps,
    required this.timeoutMinutes,
    required this.repo,
    required this.workspaceFingerprint,
    required this.baseCheckpoint,
    required this.baseState,
    required this.baseLabel,
    required this.baseCommit,
    required this.brief,
    required this.planner,
    required this.timelines,
    this.status = 'planned',
    this.picked,
    this.seconds = 0,
  });

  /// "archived" for every timeline but the picked one, once one is picked.
  String pickState(Timeline timeline) => picked == null
      ? 'not picked yet'
      : picked == timeline.k
      ? 'picked'
      : 'archived';

  Map<String, Object?> toJson() => {
    'command': 'doc.timelines',
    'version': 1,
    'id': id,
    'createdAt': createdAt,
    'status': status,
    'task': task,
    'test': test,
    'setup': setup,
    'links': links,
    'maxSteps': maxSteps,
    'timeoutMinutes': timeoutMinutes,
    'repo': repo,
    'workspaceFingerprint': workspaceFingerprint,
    'base': {
      'checkpointId': baseCheckpoint,
      'state': baseState,
      'label': baseLabel,
      'commit': baseCommit,
    },
    'brief': brief,
    'planner': planner,
    'timelines': [
      for (final t in timelines) {...t.toJson(), 'pick': pickState(t)},
    ],
    'picked': picked,
    'seconds': seconds,
  };

  static TimelineRun fromJson(Map json) {
    final base = json['base'] as Map;
    return TimelineRun(
      id: json['id'] as String,
      createdAt: json['createdAt'] as String,
      task: json['task'] as String,
      test: json['test'] as String,
      setup: json['setup'] as String?,
      links: [for (final l in (json['links'] as List? ?? const [])) '$l'],
      maxSteps: (json['maxSteps'] as num).toInt(),
      timeoutMinutes: (json['timeoutMinutes'] as num).toInt(),
      repo: json['repo'] as String,
      workspaceFingerprint: json['workspaceFingerprint'] as String,
      baseCheckpoint: base['checkpointId'] as String,
      baseState: base['state'] as String,
      baseLabel: base['label'] as String?,
      baseCommit: base['commit'] as String?,
      brief: json['brief'] as String?,
      planner: ((json['planner'] as Map?) ?? const {}).cast<String, Object?>(),
      timelines: [
        for (final t in (json['timelines'] as List).whereType<Map>())
          Timeline.fromJson(t),
      ],
      status: json['status'] as String? ?? 'planned',
      picked: (json['picked'] as num?)?.toInt(),
      seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    );
  }
}

String _clock(double seconds) {
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _statusText(Timeline t) => switch (t.status) {
  TimelineStatus.done => 'done',
  TimelineStatus.failed =>
    t.reason != null && t.reason!.contains('step(s)') ? 'step limit' : 'failed',
  TimelineStatus.timedOut => 'timed out',
  TimelineStatus.stopped => 'stopped',
  TimelineStatus.running => 'running',
  TimelineStatus.pending => 'not run',
};

/// The side-by-side comparison of a run, one block per timeline.
List<String> timelineComparison(TimelineRun run, {int tailLines = 8}) {
  final lines = <String>[];
  for (final t in run.timelines) {
    final added = t.files.fold<int>(0, (sum, f) => sum + (f.added ?? 0));
    final removed = t.files.fold<int>(0, (sum, f) => sum + (f.removed ?? 0));
    final test = t.test;
    final testText = test == null
        ? 'not run'
        : test.passed
        ? 'PASS (${test.seconds.toStringAsFixed(1)}s)'
        : test.setupFailed
        ? 'FAIL (setup failed)'
        : test.timedOut
        ? 'FAIL (timed out)'
        : 'FAIL (${test.seconds.toStringAsFixed(1)}s)';
    lines
      ..add('[${t.k}] ${t.approach.title}')
      ..add(
        '    agent: ${_statusText(t)}, ${t.steps} step(s), ${_clock(t.seconds)}'
        '${t.costUsd == null ? '' : ', \$${t.costUsd!.toStringAsFixed(4)}'}'
        '${t.reason != null && t.status != TimelineStatus.done ? ' (${t.reason})' : ''}',
      )
      ..add(
        '    files: ${t.files.isEmpty ? 'no changes' : t.files.map((f) => f.added == null ? '${f.path} (binary)' : '${f.path} +${f.added} −${f.removed}').join(', ')}'
        '${t.files.length > 1 ? '  (total +$added −$removed)' : ''}',
      )
      ..add('    tests: $testText')
      ..add('    branch: ${t.branch}  (${run.pickState(t)})');
    if (test != null && !test.passed && test.tail.trim().isNotEmpty) {
      final tail = const LineSplitter().convert(test.tail.trimRight());
      for (final line in tail.skip(max(0, tail.length - tailLines))) {
        lines.add('      | $line');
      }
    }
  }
  return lines;
}
