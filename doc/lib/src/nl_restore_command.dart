import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'abandoned_work.dart';
import 'cli.dart';
import 'dmc_client.dart';
import 'lesson_commands.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'nl_restore.dart';

/// Room for reasoning plus the small JSON answer.
const int nlRestoreMaxTokens = 2000;

/// Largest file (either side) whose lines are counted and diffed.
const int nlRestoreFileLimitBytes = 1024 * 1024;

/// `doc restore "<request>"`: natural-language restore.
///
/// The `restore` role reads the request and a list of recent closed
/// checkpoints (labels and paths only, redacted) and names one checkpoint
/// and a mode. Doc validates that answer ([planNaturalRestore]), asks the
/// user to pick when it is unsure, previews every step with dmc, shows one
/// combined plan, and applies it through dmc's journaled restore only after
/// one confirmation. The model never chooses files or actions.
Future<int> runNaturalRestore(DocContext context, String request) async {
  final args = context.args;
  final json = args['json'] as bool;
  final yes = args['yes'] as bool;
  final limitText = args['limit'] as String?;
  final limit = limitText == null
      ? nlRestoreDefaultLimit
      : int.tryParse(limitText) ?? -1;
  if (limit < 1) {
    context.log('--limit takes a positive number of checkpoints.');
    return 2;
  }
  // In --json mode stdout holds only the result; the rest goes to stderr.
  void say(String line) => json ? context.log(line) : context.out.writeln(line);
  String? ask(String question) {
    if (json) {
      context.log(question.trimRight());
    } else {
      context.out.write(question);
    }
    return context.readLine();
  }

  bool confirm(String question, {required bool byDefault}) {
    if (yes) {
      say('${question}yes (--yes)');
      return true;
    }
    final answer = (ask(question) ?? '').trim().toLowerCase();
    if (answer.isEmpty) return byDefault;
    return answer == 'y' || answer == 'yes';
  }

  final report = <String, Object?>{
    'command': 'doc.restore',
    'request': request,
  };
  int finish(int code, String status, [Map<String, Object?> extra = const {}]) {
    report['result'] = {'status': status, ...extra};
    if (json) context.out.writeln(jsonEncode(report));
    return code;
  }

  // 1. Candidates: deterministic, from dmc.
  final DmcClient dmc;
  final List<RestoreCandidate> candidates;
  try {
    dmc = await context.dmc();
    final listed = await dmc.runJson([
      'checkpoint',
      'list',
      '--limit',
      '1000',
    ], workspace: context.workspace);
    if (listed['ok'] != true) {
      context.log('dmc checkpoint list failed: ${_errors(listed)}');
      return 1;
    }
    final items = ((listed['data'] as Map)['checkpoints'] as List)
        .whereType<Map>()
        .toList();
    candidates = [];
    for (final item in recentClosedCheckpoints(items, limit)) {
      final show = await dmc.runJson([
        'checkpoint',
        'show',
        item['id'] as String,
      ], workspace: context.workspace);
      if (show['ok'] != true) {
        context.log(
          'dmc checkpoint show ${item['id']} failed: ${_errors(show)}',
        );
        return 1;
      }
      candidates.add(RestoreCandidate.fromDmc(item, show['data'] as Map));
    }
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
  report['candidates'] = [for (final c in candidates) c.toJson()];
  if (candidates.isEmpty) {
    say('There are no closed checkpoints to restore.');
    return finish(1, 'noCandidates');
  }

  // 2. The model names a mode and a checkpoint.
  final messages = [
    const ChatMessage('system', nlRestoreSystemPrompt),
    ChatMessage('user', nlRestoreUserMessage(request, candidates)),
  ];
  final responseFormat = nlRestoreResponseFormat(candidates);
  if (args['show-prompt'] as bool) {
    final prepared = context.router.prepare(
      'restore',
      messages,
      maxTokens: nlRestoreMaxTokens,
      responseFormat: responseFormat,
    );
    say(
      'Would send to ${prepared.route.provider.id} (${prepared.route.model}) at '
      '${prepared.route.provider.baseUrl}/chat/completions. Nothing was sent.',
    );
    say('Redacted: ${prepared.redactionCount} item(s)');
    if (json) {
      report['prompt'] = prepared.body;
      return finish(0, 'promptShown');
    }
    say(const JsonEncoder.withIndent('  ').convert(prepared.body));
    return 0;
  }

  NlRestorePlan? plan;
  String? problem;
  var sent = messages;
  var cost = 0.0;
  var promptTokens = 0;
  var completionTokens = 0;
  var attempts = 0;
  var redactions = 0;
  RoleCallResult? call;
  for (var attempt = 1; attempt <= 2 && plan == null; attempt++) {
    try {
      call = await context.router.call(
        'restore',
        sent,
        maxTokens: nlRestoreMaxTokens,
        responseFormat: responseFormat,
      );
    } on ModelCallException catch (error) {
      context.log(
        explainFailure(
          error,
          context.config.providers[error.provider] ??
              context.router.resolve('restore').provider,
          role: 'restore',
          localOnly: context.router.localOnly,
        ),
      );
      say('Nothing was changed.');
      return finish(1, 'modelFailed', {'error': error.message});
    }
    attempts = attempt;
    cost += call.costUsd;
    promptTokens += call.result.promptTokens;
    completionTokens += call.result.completionTokens;
    redactions = call.redactionCount;
    try {
      plan = planNaturalRestore(
        parseNlRestoreAnswer(call.result.content),
        candidates,
      );
      report['answer'] = parseNlRestoreAnswer(call.result.content).toJson();
    } on NlRestoreRefused catch (error) {
      problem = error.message;
      if (attempt == 1) {
        context.log(
          'The answer could not be used ($problem) Asking once more.',
        );
        sent = [
          ...messages,
          ChatMessage('assistant', call.result.content),
          ChatMessage(
            'user',
            'That answer was not usable: $problem Answer again with only the JSON object, using an id from the list.',
          ),
        ];
      }
    }
  }
  final answeredBy = context.config.providers[call!.result.provider];
  report['model'] = {
    'provider': call.result.provider,
    'model': call.result.model,
    'fellBackFrom': call.fellBackFrom,
    'responseFormat': answeredBy?.jsonSchema ?? false,
    'attempts': attempts,
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'costUsd': cost,
    'redactionCount': redactions,
  };
  final footer =
      '${call.result.provider} ${call.result.model}; $promptTokens in / $completionTokens out; '
      '\$${cost.toStringAsFixed(6)}; $redactions item(s) redacted'
      '${call.fellBackFrom == null ? '' : '; fell back from ${call.fellBackFrom}'}';
  if (plan == null) {
    say('Doc refused the model\'s answer: $problem');
    say('Nothing was changed. ($footer)');
    return finish(1, 'refused', {'reason': problem});
  }
  say(
    'Doc\'s reading ($footer; confidence ${plan.confidence.toStringAsFixed(2)}):',
  );
  say('  ${_modeText(plan.mode, plan.target)}: ${plan.reason}');

  // 3. Low confidence or alternatives: the user picks. Never --yes.
  if (plan.needsChoice) {
    final choices = plan.choices;
    say('');
    say(
      plan.confidence < nlRestoreMinConfidence
          ? 'Doc is not sure enough to pick for you (confidence ${plan.confidence.toStringAsFixed(2)}). Which checkpoint did you mean?'
          : 'More than one checkpoint could match. Which did you mean?',
    );
    for (var i = 0; i < choices.length; i++) {
      final c = choices[i];
      say('  ${i + 1}. ${c.time}  ${c.who}  ${c.displayLabel}');
      say('     ${c.id}${c.alreadyUndone ? ' (already undone)' : ''}');
      say('     files: ${c.fileList}');
    }
    final answer =
        (ask(
                  'Pick 1-${choices.length} to ${plan.mode == NlRestoreMode.goBackBefore ? 'go back to before it' : 'undo only that turn'}, or press Enter to cancel: ',
                ) ??
                '')
            .trim();
    final picked = int.tryParse(answer);
    report['choice'] = {
      'needed': true,
      'choices': [for (final c in choices) c.id],
      'picked': picked != null && picked >= 1 && picked <= choices.length
          ? choices[picked - 1].id
          : null,
    };
    if (picked == null || picked < 1 || picked > choices.length) {
      say('Cancelled. Nothing was changed.');
      return finish(0, 'cancelled');
    }
    plan = planFor(
      plan.mode,
      choices[picked - 1],
      candidates,
      confidence: plan.confidence,
      reason: plan.reason,
    );
  } else {
    report['choice'] = {'needed': false};
  }
  report['plan'] = plan.toJson();
  for (final c in plan.alreadyUndone) {
    say('Already undone, skipped: ${c.id} (${c.who}): ${c.displayLabel}');
  }
  if (plan.steps.isEmpty) {
    say('Nothing to restore: that work is already undone.');
    return finish(0, 'nothingToDo');
  }

  // 4. Preview every step with dmc and combine them (nothing changes yet).
  final previews = <NlStepPreview>[];
  for (final step in plan.steps) {
    previews.add(
      NlStepPreview(
        step,
        await dmc.runJson([
          'checkpoint',
          'restore',
          step.id,
        ], workspace: context.workspace),
      ),
    );
  }
  final combined = combineStepPreviews(previews);
  final contents = await _contents(context, dmc, combined);
  final steps = plan.steps;

  say('');
  say(
    'Plan: ${_modeText(plan.mode, plan.target)} (${steps.length} step(s), newest first):',
  );
  for (var i = 0; i < steps.length; i++) {
    final c = steps[i];
    say('  ${i + 1}. ${c.id}  ${c.time}  ${c.who}: ${c.displayLabel}');
  }
  final changing = combined.changing;
  final fileReport = <Map<String, Object?>>[];
  if (changing.isNotEmpty) {
    say('Files that will change (against the working copy):');
    final width = changing.fold(
      0,
      (w, f) => f.path.length > w ? f.path.length : w,
    );
    for (final file in changing) {
      final text = contents[file.path];
      final counts = text == null
          ? null
          : lineCounts(text.current, text.result);
      fileReport.add({
        'path': file.path,
        'action': file.description,
        'currentStep': file.currentStep + 1,
        'finalStep': file.finalStep + 1,
        'added': counts?.added,
        'removed': counts?.removed,
        'binary': counts == null,
      });
      say(
        '  - ${file.path.padRight(width)}  ${counts == null ? '(binary or large)' : '+${counts.added} −${counts.removed}'}  ${file.description}',
      );
    }
  }
  final unchanged = [
    for (final file in combined.files)
      if (!file.netChange) file.path,
  ];
  if (unchanged.isNotEmpty) {
    say('No net change (the steps cancel out): ${unchanged.join(', ')}');
  }
  if (combined.skipped.isNotEmpty) {
    say('Left alone (protection changed during a turn; never written):');
    for (final item in combined.skipped) {
      say(
        '  - ${item.path} (step ${_stepOf(steps, item.checkpointId)}): ${item.code}',
      );
    }
  }
  report['preview'] = {
    'files': fileReport,
    'noNetChange': unchanged,
    'skipped': [
      for (final item in combined.skipped)
        {
          'checkpointId': item.checkpointId,
          'path': item.path,
          'code': item.code,
        },
    ],
    'conflicts': [for (final c in combined.conflicts) c.toJson()],
  };
  if (args['diff'] as bool) {
    for (final file in changing) {
      final text = contents[file.path];
      say('');
      say('--- ${file.path} (now)');
      say('+++ ${file.path} (after the restore)');
      if (text == null) {
        say('(binary or large; not shown)');
        continue;
      }
      for (final line in unifiedLineDiff(
        text.current ?? '',
        text.result ?? '',
        context: 3,
      )) {
        say(line);
      }
    }
  }
  if (!combined.canApply) {
    say('dmc will not restore this plan as it stands:');
    for (final conflict in combined.conflicts) {
      say(
        '  - step ${_stepOf(steps, conflict.checkpointId)} (${conflict.checkpointId}): ${conflict.path ?? '(checkpoint)'}: ${conflict.code}: ${conflict.message}',
      );
    }
    say(
      'Nothing was changed. Resolve the conflicts (for example, save or undo your later edits) and try again; Doc never forces a restore.',
    );
    return finish(4, 'blocked');
  }
  if (changing.isEmpty) {
    say('Nothing to restore: the working copy already matches that state.');
    return finish(0, 'nothingToDo');
  }

  // 5. One confirmation, then dmc's journaled restore, step by step.
  if (!confirm(
    'Apply this restore (${steps.length} step(s), ${changing.length} file(s))? [y/N] ',
    byDefault: false,
  )) {
    say('Nothing was changed.');
    return finish(0, 'declined');
  }
  final applied = <({String checkpointId, String? operationId})>[];
  for (var i = 0; i < steps.length; i++) {
    final step = steps[i];
    final result = await dmc.runJson([
      'checkpoint',
      'restore',
      step.id,
      '--apply',
    ], workspace: context.workspace);
    final data = (result['data'] as Map?) ?? const {};
    if (result['ok'] == true) {
      applied.add((
        checkpointId: step.id,
        operationId: data['operationId'] as String?,
      ));
      say(
        data['noOp'] == true
            ? 'Step ${i + 1} of ${steps.length}: nothing to restore for ${step.id} (it changed no files).'
            : 'Step ${i + 1} of ${steps.length}: restored ${step.id} through dmc (operation ${data['operationId']}).',
      );
      continue;
    }
    final code = (result['exitCode'] as num?)?.toInt() ?? 1;
    say('Step ${i + 1} of ${steps.length} (${step.id}) failed:');
    for (final error
        in (result['errors'] as List? ?? const []).whereType<Map>()) {
      say(
        '  - ${error['path'] == null ? '' : '${error['path']}: '}${error['code']}: ${error['message']}',
      );
    }
    final operation = data['operationId'];
    String? recover;
    if (code == 6 && operation != null) {
      recover = 'dmc checkpoint recover $operation --resume';
      say(
        'Its journal is incomplete. Recover with: $recover (or --rollback). Doc does not recover it for you.',
      );
    }
    say(
      applied.isEmpty
          ? 'No step was applied.'
          : 'Applied before the failure: ${applied.map((a) => a.checkpointId).join(', ')}.',
    );
    final putBack = <Map<String, Object?>>[];
    if (applied.isNotEmpty) {
      final answer = (ask('Put back the steps already applied? [y/N] ') ?? '')
          .trim()
          .toLowerCase();
      if (answer == 'y' || answer == 'yes') {
        for (final done in applied.reversed) {
          final redo = await dmc.runJson([
            'checkpoint',
            'redo',
            done.checkpointId,
            '--apply',
          ], workspace: context.workspace);
          final ok = redo['ok'] == true;
          putBack.add({'checkpointId': done.checkpointId, 'ok': ok});
          say(
            ok
                ? 'Put back ${done.checkpointId} (dmc redo, operation ${(redo['data'] as Map?)?['operationId']}).'
                : 'Could not put back ${done.checkpointId}: ${_errors(redo)}. Stopped; nothing else was changed.',
          );
          if (!ok) break;
        }
      } else {
        say(
          'Left as is. To put them back later: ${applied.reversed.map((a) => 'dmc checkpoint redo ${a.checkpointId} --apply').join(', then ')}.',
        );
      }
    }
    return finish(code, 'failed', {
      'failedStep': step.id,
      'errors': result['errors'],
      'recoverCommand': recover,
      'applied': [
        for (final a in applied)
          {'checkpointId': a.checkpointId, 'operationId': a.operationId},
      ],
      'putBack': putBack,
    });
  }
  say(
    'Restored ${changing.length} file(s) in ${steps.length} step(s) through dmc.',
  );
  final appliedJson = [
    for (final a in applied)
      {'checkpointId': a.checkpointId, 'operationId': a.operationId},
  ];

  // 6. The lesson offer, for the oldest undone turn with the rest as context.
  if (args['no-lesson'] as bool) {
    return finish(0, 'applied', {'applied': appliedJson});
  }
  final oldest = plan.oldestStep!;
  if (!confirm(
    'Draft a lesson from the work you just undid? [Y/n] ',
    byDefault: true,
  )) {
    say('No lesson drafted. You can still run: doc lesson draft ${oldest.id}');
    return finish(0, 'applied', {'applied': appliedJson});
  }
  var note = args['note'] as String?;
  if (note == null && !yes) {
    final answer = ask(
      'What went wrong? (optional, press Enter to skip) ',
    )?.trim();
    if (answer != null && answer.isNotEmpty) note = answer;
  }
  final later = steps.take(steps.length - 1).toList();
  final related = later.isEmpty
      ? null
      : [
          'This restore also undid ${later.length} later checkpoint(s), newest first:',
          for (final c in later)
            '- ${c.who}: ${c.modelLabel}; changed: ${c.fileList}',
        ].join('\n');
  final lessonOut = StringBuffer();
  final lessonContext = json
      ? DocContext(
          args: context.args,
          env: context.env,
          config: context.config,
          configFile: context.configFile,
          router: context.router,
          out: lessonOut,
          log: context.log,
          readLine: context.readLine,
        )
      : context;
  final lessonCode = await draftLesson(
    lessonContext,
    oldest.id,
    note: note,
    related: related,
  );
  // The restore succeeded; a failed draft does not change the exit code.
  return finish(0, 'applied', {
    'applied': appliedJson,
    'lesson': {
      'checkpointId': oldest.id,
      'exitCode': lessonCode,
      if (json) 'output': '$lessonOut',
    },
  });
}

String _modeText(NlRestoreMode mode, RestoreCandidate target) =>
    mode == NlRestoreMode.goBackBefore
    ? 'go back to before ${target.id} (${target.who}, ${target.time})'
    : 'undo only ${target.id} (${target.who}, ${target.time})';

int _stepOf(List<RestoreCandidate> steps, String id) =>
    steps.indexWhere((c) => c.id == id) + 1;

String _errors(Map<String, Object?> envelope) =>
    (envelope['errors'] as List? ?? const [])
        .whereType<Map>()
        .map((error) => '${error['code']}: ${error['message']}')
        .join('; ');

/// The text of each changing file now and after the plan, from dmc
/// exports into a temporary directory outside the workspace. "Now" is the
/// after state of the newest step that touches the file, which dmc's
/// preview has just verified matches the working copy (SHA-256), so Doc
/// never reads the workspace. Binary or large files map to null.
Future<Map<String, ({String? current, String? result})?>> _contents(
  DocContext context,
  DmcClient dmc,
  NlCombinedPlan combined,
) async {
  final wanted = <(int, String), Set<String>>{};
  for (final file in combined.changing) {
    if (!file.current.absent) {
      (wanted[(file.currentStep, 'after')] ??= {}).add(file.path);
    }
    if (!file.result.absent) {
      (wanted[(file.finalStep, 'before')] ??= {}).add(file.path);
    }
  }
  final read = <(int, String, String), Object?>{};
  final temporary = Directory.systemTemp.createTempSync('doc-restore-');
  try {
    for (final entry in wanted.entries) {
      final (step, state) = entry.key;
      final target = p.join(temporary.path, '$step-$state');
      final exported = await dmc.runJson([
        'checkpoint',
        'export',
        combined.steps[step].id,
        '--state',
        state,
        '--to',
        target,
      ], workspace: context.workspace);
      if (exported['ok'] != true) {
        context.log(
          'Could not export step ${step + 1} ($state) for line counts: ${_errors(exported)}',
        );
        for (final path in entry.value) {
          read[(step, state, path)] = _unreadable;
        }
        continue;
      }
      for (final path in entry.value) {
        read[(step, state, path)] = _readText(
          p.joinAll([target, ...path.split('/')]),
        );
      }
      Directory(target).deleteSync(recursive: true);
    }
  } on DmcException catch (error) {
    context.log('Could not export for line counts: ${error.message}');
  } finally {
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: it is a temporary directory.
    }
  }
  final contents = <String, ({String? current, String? result})?>{};
  for (final file in combined.changing) {
    final current = file.current.absent
        ? null
        : read[(file.currentStep, 'after', file.path)] ?? _unreadable;
    final result = file.result.absent
        ? null
        : read[(file.finalStep, 'before', file.path)] ?? _unreadable;
    contents[file.path] =
        identical(current, _unreadable) || identical(result, _unreadable)
        ? null
        : (current: current as String?, result: result as String?);
  }
  return contents;
}

final Object _unreadable = Object();

Object? _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  if (file.lengthSync() > nlRestoreFileLimitBytes) return _unreadable;
  final bytes = file.readAsBytesSync();
  if (bytes.contains(0)) return _unreadable;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _unreadable;
  }
}
