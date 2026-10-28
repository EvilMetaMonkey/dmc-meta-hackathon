import 'dart:convert';

import 'abandoned_work.dart';
import 'summarize.dart';

/// Natural-language restore, the deterministic part: the candidates Doc
/// shows the model, the validation of the model's answer into a plan, and
/// the combination of dmc's per-step previews into one plan. Nothing here
/// runs dmc or a model; `nl_restore_command.dart` does.

/// Below this confidence Doc never picks for the user.
const double nlRestoreMinConfidence = 0.6;

/// Default number of recent closed checkpoints offered to the model.
const int nlRestoreDefaultLimit = 30;

enum NlRestoreMode {
  /// Undo the checkpoint and every later candidate, newest first.
  goBackBefore('go_back_before'),

  /// Undo that one checkpoint only.
  undoTurn('undo_turn');

  final String wire;
  const NlRestoreMode(this.wire);

  static NlRestoreMode? parse(Object? value) {
    for (final mode in values) {
      if (mode.wire == value) return mode;
    }
    return null;
  }
}

/// One recorded file state (dmc's `before` or `after` object).
class NlFileState {
  final String kind;
  final String? hash;
  final int? mode;

  const NlFileState(this.kind, this.hash, this.mode);

  static NlFileState? fromJson(Object? json) => json is Map
      ? NlFileState(
          json['kind'] as String,
          json['hash'] as String?,
          (json['mode'] as num?)?.toInt(),
        )
      : null;

  bool get absent => kind == 'absent';

  /// The same rule dmc uses: kind, and for files the hash and (when both are
  /// known) the mode.
  bool sameAs(NlFileState other) =>
      kind == other.kind &&
      (absent ||
          (hash == other.hash &&
              (mode == null || other.mode == null || mode == other.mode)));
}

/// A file a checkpoint changed, from `dmc checkpoint show`.
class NlCandidateFile {
  final String path;

  /// dmc's change kind, or its scope change (`left_scope`, `entered_scope`).
  final String change;
  final NlFileState before;
  final NlFileState? after;

  /// Set for files whose protection changed; dmc never writes them.
  final String? scope;

  const NlCandidateFile({
    required this.path,
    required this.change,
    required this.before,
    required this.after,
    this.scope,
  });

  /// Whether a restore of this checkpoint writes this file.
  bool get restorable => scope == null && after != null;
}

/// One closed checkpoint the model may choose.
class RestoreCandidate {
  final String id;
  final String source;
  final String? agent;
  final String? session;
  final String? label;
  final int createdAt;
  final int? closedAt;
  final List<NlCandidateFile> files;

  /// Its latest completed operation is a restore that no later redo
  /// reapplied: the work is already undone.
  final bool alreadyUndone;

  const RestoreCandidate({
    required this.id,
    required this.source,
    required this.agent,
    required this.session,
    required this.label,
    required this.createdAt,
    required this.closedAt,
    required this.files,
    this.alreadyUndone = false,
  });

  /// From one `checkpoint list` item and that checkpoint's `checkpoint show`
  /// data (files and operations).
  factory RestoreCandidate.fromDmc(Map listItem, Map showData) {
    final agent = listItem['agent'];
    final files = <NlCandidateFile>[];
    for (final file
        in (showData['files'] as List? ?? const []).whereType<Map>()) {
      final scope = file['scope'] as String?;
      final change = file['change'] as String?;
      if (scope == null && (change == null || change == 'unchanged')) {
        continue;
      }
      files.add(
        NlCandidateFile(
          path: file['path'] as String,
          change: scope ?? change!,
          before: NlFileState.fromJson(file['before'])!,
          after: NlFileState.fromJson(file['after']),
          scope: scope,
        ),
      );
    }
    final operations = [
      for (final operation
          in (showData['operations'] as List? ??
                  listItem['operations'] as List? ??
                  const [])
              .whereType<Map>())
        if (operation['status'] == 'completed') operation,
    ];
    int completed(Map operation) =>
        (operation['completedAt'] as num?)?.toInt() ?? 0;
    operations.sort((a, b) => completed(a).compareTo(completed(b)));
    return RestoreCandidate(
      id: listItem['id'] as String,
      source: listItem['source'] as String,
      agent: agent is Map ? agent['name'] as String? : null,
      session: agent is Map ? agent['sessionId'] as String? : null,
      label: listItem['label'] as String?,
      createdAt: (listItem['createdAt'] as num).toInt(),
      closedAt: (listItem['closedAt'] as num?)?.toInt(),
      files: files,
      alreadyUndone:
          operations.isNotEmpty && operations.last['direction'] == 'restore',
    );
  }

  String get who => agent ?? source;

  /// dmc keeps an agent prompt's first line, cut to 100 characters with "…".
  bool get labelTruncated => label?.endsWith('…') ?? false;

  /// The label for people: a cut label says so.
  String get displayLabel {
    final text = label ?? '(no label)';
    return labelTruncated ? '$text (truncated by dmc)' : text;
  }

  /// The label for a model: a cut label carries [truncatedLabelMarker].
  String get modelLabel {
    if (label == null || label!.isEmpty) return '(no label)';
    return labelTruncated
        ? '${label!.substring(0, label!.length - 1).trimRight()} $truncatedLabelMarker'
        : label!;
  }

  /// Local close time (else creation time) as `YYYY-MM-DD HH:MM:SS`.
  String get time {
    final at = DateTime.fromMillisecondsSinceEpoch(closedAt ?? createdAt);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
  }

  String get fileList => files.isEmpty
      ? '(no files changed)'
      : files.map((file) => '${file.path} (${file.change})').join(', ');

  Map<String, Object?> toJson() => {
    'id': id,
    'time': time,
    'createdAt': createdAt,
    'closedAt': closedAt,
    'agent': agent,
    'session': session,
    'source': source,
    'label': label,
    'labelTruncated': labelTruncated,
    'alreadyUndone': alreadyUndone,
    'files': [
      for (final file in files) {'path': file.path, 'change': file.change},
    ],
  };
}

/// The closed checkpoints offered to the model: the [limit] most recent,
/// newest first. [items] is `checkpoint list` data, in any order.
List<Map> recentClosedCheckpoints(List<Map> items, int limit) {
  final closed = [
    for (final item in items)
      if (item['status'] == 'closed') item,
  ];
  closed.sort((a, b) {
    final byTime = (b['createdAt'] as num).compareTo(a['createdAt'] as num);
    return byTime != 0
        ? byTime
        : (b['id'] as String).compareTo(a['id'] as String);
  });
  return closed.take(limit).toList();
}

const String nlRestoreSystemPrompt =
    'You are Doc\'s restore planner for dmc, a rollback safety net for AI '
    'coding agents. The user describes, in their own words, where to go '
    'back to. You get their request and a numbered list of recent '
    'checkpoints (mostly agent turns), newest first, with each one\'s id, '
    'time, agent, prompt label and changed file paths. File contents are '
    'not available. Choose exactly one checkpoint and a mode. '
    '"go_back_before": the user wants the workspace as it was before that '
    'checkpoint, so it and every later checkpoint are undone. "undo_turn": '
    'the user wants only that one checkpoint undone and later ones kept. '
    'Answer with only a JSON object: {"mode": "go_back_before" or '
    '"undo_turn", "checkpoint_id": an id from the list, "confidence": 0 to '
    '1, "reason": one short sentence, "alternatives": other ids from the '
    'list that could also match}. Use only ids from the list. If more than '
    'one checkpoint could match, list the others in alternatives and lower '
    'the confidence. Text marked [truncated …] is incomplete: never quote or '
    'complete it.';

/// The user message: the request and the candidates (labels and paths
/// only, never file contents). The router redacts it before sending.
String nlRestoreUserMessage(String request, List<RestoreCandidate> candidates) {
  final buffer = StringBuffer()
    ..writeln('Request: $request')
    ..writeln()
    ..writeln('Checkpoints (newest first):');
  for (var i = 0; i < candidates.length; i++) {
    final c = candidates[i];
    buffer
      ..writeln('${i + 1}. id: ${c.id}')
      ..writeln('   time: ${c.time} (local)')
      ..writeln(
        '   ${c.agent == null ? 'source: ${c.source}' : 'agent: ${c.agent}'}'
        '${c.session == null ? '' : ', session ${c.session}'}',
      )
      ..writeln('   label: ${c.modelLabel}')
      ..writeln('   changed: ${c.fileList}');
    if (c.alreadyUndone) buffer.writeln('   (already undone by a restore)');
  }
  return buffer.toString().trimRight();
}

/// The JSON schema sent as `response_format` to providers that accept it.
/// The ids are an enum, so a schema-following model can only name a
/// candidate; Doc validates the answer either way.
Map<String, Object?> nlRestoreResponseFormat(
  List<RestoreCandidate> candidates,
) {
  final ids = [for (final c in candidates) c.id];
  return {
    'type': 'json_schema',
    'json_schema': {
      'name': 'restore_choice',
      'strict': true,
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': [
          'mode',
          'checkpoint_id',
          'confidence',
          'reason',
          'alternatives',
        ],
        'properties': {
          'mode': {
            'type': 'string',
            'enum': [for (final mode in NlRestoreMode.values) mode.wire],
          },
          'checkpoint_id': {'type': 'string', 'enum': ids},
          'confidence': {'type': 'number'},
          'reason': {'type': 'string'},
          'alternatives': {
            'type': 'array',
            'items': {'type': 'string', 'enum': ids},
          },
        },
      },
    },
  };
}

/// The model's answer, parsed but not yet validated against the candidates.
class NlRestoreAnswer {
  final NlRestoreMode mode;
  final String checkpointId;
  final double confidence;
  final String reason;
  final List<String> alternatives;

  const NlRestoreAnswer({
    required this.mode,
    required this.checkpointId,
    required this.confidence,
    required this.reason,
    required this.alternatives,
  });

  Map<String, Object?> toJson() => {
    'mode': mode.wire,
    'checkpointId': checkpointId,
    'confidence': confidence,
    'reason': reason,
    'alternatives': alternatives,
  };
}

/// Why Doc will not act on a model answer.
class NlRestoreRefused implements Exception {
  final String message;
  const NlRestoreRefused(this.message);

  @override
  String toString() => message;
}

/// Strict parsing: one JSON object (a surrounding ```json fence is
/// tolerated) with exactly the expected types. Anything else is refused.
NlRestoreAnswer parseNlRestoreAnswer(String content) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const NlRestoreRefused('The answer was not a JSON object.');
  }
  if (json is! Map) {
    throw const NlRestoreRefused('The answer was not a JSON object.');
  }
  final mode = NlRestoreMode.parse(json['mode']);
  if (mode == null) {
    throw NlRestoreRefused(
      '"mode" must be "go_back_before" or "undo_turn", not ${jsonEncode(json['mode'])}.',
    );
  }
  final id = json['checkpoint_id'];
  if (id is! String || id.isEmpty) {
    throw const NlRestoreRefused('"checkpoint_id" must be a string.');
  }
  final confidence = json['confidence'];
  if (confidence is! num || confidence < 0 || confidence > 1) {
    throw const NlRestoreRefused('"confidence" must be a number from 0 to 1.');
  }
  final reason = json['reason'];
  if (reason is! String) {
    throw const NlRestoreRefused('"reason" must be a string.');
  }
  final alternatives = json['alternatives'] ?? const [];
  if (alternatives is! List || alternatives.any((a) => a is! String)) {
    throw const NlRestoreRefused('"alternatives" must be a list of ids.');
  }
  return NlRestoreAnswer(
    mode: mode,
    checkpointId: id,
    confidence: confidence.toDouble(),
    reason: reason.trim(),
    alternatives: alternatives.cast<String>(),
  );
}

/// A validated natural-language restore: what to undo, in which order.
class NlRestorePlan {
  final NlRestoreMode mode;
  final RestoreCandidate target;
  final double confidence;
  final String reason;

  /// Other candidates the model said could match (never the target).
  final List<RestoreCandidate> alternatives;

  /// The checkpoints to restore, newest first.
  final List<RestoreCandidate> steps;

  /// Candidates in range that are already undone and are not restored again.
  final List<RestoreCandidate> alreadyUndone;

  const NlRestorePlan({
    required this.mode,
    required this.target,
    required this.confidence,
    required this.reason,
    required this.alternatives,
    required this.steps,
    required this.alreadyUndone,
  });

  /// Low confidence or alternatives: the user must pick (never `--yes`).
  bool get needsChoice =>
      confidence < nlRestoreMinConfidence || alternatives.isNotEmpty;

  /// What the user picks from: the model's choice first, then alternatives.
  List<RestoreCandidate> get choices => [target, ...alternatives];

  /// The oldest checkpoint undone: the one a lesson is drafted from.
  RestoreCandidate? get oldestStep => steps.isEmpty ? null : steps.last;

  Map<String, Object?> toJson() => {
    'mode': mode.wire,
    'target': target.id,
    'confidence': confidence,
    'reason': reason,
    'alternatives': [for (final c in alternatives) c.id],
    'needsChoice': needsChoice,
    'steps': [for (final c in steps) c.id],
    'alreadyUndone': [for (final c in alreadyUndone) c.id],
  };
}

/// Turn a parsed model answer into a plan. Pure and deterministic: the
/// model only names a mode and a checkpoint; the steps follow from the
/// candidates ([candidates] newest first). An id that is not a candidate
/// is refused.
NlRestorePlan planNaturalRestore(
  NlRestoreAnswer answer,
  List<RestoreCandidate> candidates,
) {
  RestoreCandidate find(String id, String what) {
    for (final candidate in candidates) {
      if (candidate.id == id) return candidate;
    }
    throw NlRestoreRefused(
      'The model named $what $id, which is not one of the ${candidates.length} candidate checkpoint(s). Doc only restores a checkpoint it offered.',
    );
  }

  final target = find(answer.checkpointId, 'checkpoint');
  final alternatives = <RestoreCandidate>[];
  for (final id in answer.alternatives) {
    final alternative = find(id, 'alternative');
    if (alternative.id != target.id && !alternatives.contains(alternative)) {
      alternatives.add(alternative);
    }
  }
  return planFor(
    answer.mode,
    target,
    candidates,
    confidence: answer.confidence,
    reason: answer.reason,
    alternatives: alternatives,
  );
}

/// The plan for [mode] on [target] (also used after the user picks).
NlRestorePlan planFor(
  NlRestoreMode mode,
  RestoreCandidate target,
  List<RestoreCandidate> candidates, {
  double confidence = 1,
  String reason = '',
  List<RestoreCandidate> alternatives = const [],
}) {
  final index = candidates.indexOf(target);
  if (index < 0) {
    throw NlRestoreRefused('${target.id} is not a candidate checkpoint.');
  }
  final range = mode == NlRestoreMode.undoTurn
      ? [target]
      : candidates.sublist(0, index + 1);
  return NlRestorePlan(
    mode: mode,
    target: target,
    confidence: confidence,
    reason: reason,
    alternatives: alternatives,
    steps: [
      for (final c in range)
        if (!c.alreadyUndone) c,
    ],
    alreadyUndone: [
      for (final c in range)
        if (c.alreadyUndone) c,
    ],
  );
}

/// dmc's preview of one step (`checkpoint restore <id> --json`).
class NlStepPreview {
  final RestoreCandidate step;
  final Map<String, Object?> envelope;

  const NlStepPreview(this.step, this.envelope);

  Map get _data => (envelope['data'] as Map?) ?? const {};

  List<Map> _list(String key) =>
      (_data[key] as List? ?? const []).whereType<Map>().toList();

  Set<String> get actionPaths => {
    for (final action in _list('actions')) action['path'] as String,
  };
  List<Map> get conflicts => _list('conflicts');
  List<Map> get dataErrors => _list('dataErrors');
  List<Map> get skipped => _list('skipped');

  /// Envelope errors that are not per-file conflicts (for example a
  /// checkpoint that cannot be restored).
  List<Map> get otherErrors {
    final known = {
      for (final issue in [...conflicts, ...dataErrors])
        '${issue['code']}\u0000${issue['path']}',
    };
    return [
      for (final error
          in (envelope['errors'] as List? ?? const []).whereType<Map>())
        if (!known.contains('${error['code']}\u0000${error['path']}')) error,
    ];
  }
}

/// A conflict that blocks the combined plan.
class NlConflict {
  final String checkpointId;
  final String? path;
  final String code;
  final String message;

  const NlConflict(this.checkpointId, this.path, this.code, this.message);

  Map<String, Object?> toJson() => {
    'checkpointId': checkpointId,
    'path': path,
    'code': code,
    'message': message,
  };
}

/// One file in the combined plan: its state now and after every step.
class NlPlannedFile {
  final String path;

  /// The step (index into the plan's steps) whose after state is the
  /// current working copy: the newest step that touches the file.
  final int currentStep;

  /// The step whose before state is the result: the oldest that touches it.
  final int finalStep;
  final NlFileState current;
  final NlFileState result;

  const NlPlannedFile({
    required this.path,
    required this.currentStep,
    required this.finalStep,
    required this.current,
    required this.result,
  });

  /// The steps cancel out (for example created, then deleted again).
  bool get netChange => !current.sameAs(result);

  String get description {
    if (!netChange) return 'no net change';
    if (result.absent) return 'delete it';
    if (current.absent) return 'recreate it';
    return 'put back the version from before step ${finalStep + 1}';
  }
}

/// dmc's previews combined into one plan, in step order.
class NlCombinedPlan {
  final List<RestoreCandidate> steps;
  final List<NlPlannedFile> files;
  final List<({String checkpointId, String path, String code})> skipped;
  final List<NlConflict> conflicts;

  const NlCombinedPlan({
    required this.steps,
    required this.files,
    required this.skipped,
    required this.conflicts,
  });

  bool get canApply => conflicts.isEmpty;

  List<NlPlannedFile> get changing => [
    for (final file in files)
      if (file.netChange) file,
  ];
}

/// Combine one preview per step ([previews] in step order, newest first).
///
/// dmc previews every step against the current working copy, so an older
/// step that touches a file a newer step also restores reports a
/// `workspace_drift` conflict on it. Doc follows the chain instead: that
/// file is fine when the newer step puts back exactly the state the older
/// step expects (its after state); otherwise the file changed between the
/// turns and it is a real conflict. Files no newer step touches keep dmc's
/// verdict. dmc checks every step again when it is applied.
NlCombinedPlan combineStepPreviews(List<NlStepPreview> previews) {
  final conflicts = <NlConflict>[];
  final skipped = <({String checkpointId, String path, String code})>[];
  // Path -> (state after the steps so far, step that set it).
  final pending = <String, ({NlFileState state, int step})>{};
  final current = <String, ({NlFileState state, int step})>{};
  for (var index = 0; index < previews.length; index++) {
    final preview = previews[index];
    final step = preview.step;
    final restorable = {
      for (final file in step.files)
        if (file.restorable) file.path: file,
    };
    final actionPaths = preview.actionPaths;
    // Files a newer step also touches: Doc's verdict replaces dmc's.
    final chained = <String>{};
    for (final file in restorable.values) {
      final earlier = pending[file.path];
      if (earlier != null) {
        if (earlier.state.sameAs(file.after!)) {
          chained.add(file.path);
        } else {
          chained.add(file.path);
          conflicts.add(
            NlConflict(
              step.id,
              file.path,
              'chain_mismatch',
              'After step ${earlier.step + 1} this file will not match what step ${index + 1} expects; it changed between the two turns.',
            ),
          );
          continue;
        }
      } else if (!actionPaths.contains(file.path)) {
        // dmc's own verdict; its conflict is reported below.
        continue;
      }
      current.putIfAbsent(file.path, () => (state: file.after!, step: index));
      pending[file.path] = (state: file.before, step: index);
    }
    for (final conflict in preview.conflicts) {
      final path = conflict['path'] as String?;
      if (path != null && chained.contains(path)) continue;
      conflicts.add(
        NlConflict(
          step.id,
          path,
          '${conflict['code']}',
          '${conflict['message']}',
        ),
      );
    }
    for (final issue in [...preview.dataErrors, ...preview.otherErrors]) {
      conflicts.add(
        NlConflict(
          step.id,
          issue['path'] as String?,
          '${issue['code']}',
          '${issue['message']}',
        ),
      );
    }
    if (preview.envelope['ok'] != true &&
        preview.conflicts.isEmpty &&
        preview.dataErrors.isEmpty &&
        preview.otherErrors.isEmpty) {
      conflicts.add(
        NlConflict(
          step.id,
          null,
          'preview_failed',
          'dmc could not preview this step.',
        ),
      );
    }
    for (final item in preview.skipped) {
      skipped.add((
        checkpointId: step.id,
        path: '${item['path']}',
        code: '${item['code']}',
      ));
    }
  }
  final files = [
    for (final entry in current.entries)
      NlPlannedFile(
        path: entry.key,
        currentStep: entry.value.step,
        finalStep: pending[entry.key]!.step,
        current: entry.value.state,
        result: pending[entry.key]!.state,
      ),
  ]..sort((a, b) => a.path.compareTo(b.path));
  return NlCombinedPlan(
    steps: [for (final preview in previews) preview.step],
    files: files,
    skipped: skipped,
    conflicts: conflicts,
  );
}

/// Lines added and removed going from [from] to [to] (null = absent).
({int added, int removed}) lineCounts(String? from, String? to) {
  var added = 0;
  var removed = 0;
  for (final line in unifiedLineDiff(from ?? '', to ?? '', context: 0)) {
    if (line.startsWith('+')) added++;
    if (line.startsWith('-')) removed++;
  }
  return (added: added, removed: removed);
}
