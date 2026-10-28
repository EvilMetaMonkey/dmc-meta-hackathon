import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'abandoned_work.dart';
import 'cli.dart';
import 'dmc_client.dart';
import 'lessons.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'summarize.dart';

/// Room for reasoning plus a ~150-word draft or a ~100-word brief.
const int lessonMaxTokens = 2000;

const String draftSystemPrompt =
    'You draft lessons for a library of mistakes coding agents must not '
    'repeat. From the checkpoint facts and the user\'s note, write exactly: '
    'a first line "Title: <short imperative title>", then three sections '
    'headed "## What was tried", "## Why it failed" and "## What to do '
    'instead". At most 150 words in all. Use only the facts and the diff '
    'given. Text marked [truncated …] is incomplete: never quote or '
    'complete it. No preamble.';

const String briefSystemPrompt =
    'You are Doc. A coding agent is about to start the task below. Condense '
    'the lessons into one brief written to the agent, at most 100 words, '
    'plain text, starting with "Before you start:". Name the files and say '
    'what to avoid and what to do instead. No preamble, no lists, no '
    'markdown.';

/// dmc's view of the workspace: its identity and the files it protects.
class _Workspace {
  final DmcClient dmc;
  final String root;
  final String fingerprint;

  const _Workspace(this.dmc, this.root, this.fingerprint);
}

Future<_Workspace> _workspace(DocContext context) async {
  final dmc = await context.dmc();
  final listed = await dmc.runJson([
    'checkpoint',
    'list',
    '--limit',
    '1',
  ], workspace: context.workspace);
  final workspace = listed['workspace'];
  if (listed['ok'] != true || workspace is! Map) {
    throw DmcException(
      'dmc could not identify the workspace ${context.workspace}: ${_errors(listed)}',
    );
  }
  return _Workspace(
    dmc,
    workspace['path'] as String,
    workspace['fingerprint'] as String,
  );
}

String _errors(Map<String, Object?> envelope) =>
    (envelope['errors'] as List? ?? const [])
        .whereType<Map>()
        .map((error) => '${error['code']}: ${error['message']}')
        .join('; ');

LessonStore _store(DocContext context, _Workspace workspace) =>
    LessonStore.forWorkspace(
      dataDirectory: docDataDirectory(context.env),
      fingerprint: workspace.fingerprint,
      workspacePath: workspace.root,
    );

List<String> _files(DocContext context) => [
  for (final value in context.args['files'] as List<String>)
    ...value
        .split(',')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty),
];

/// `doc lesson <draft|edit|approve|reject|show|brief> ...`
Future<int> runLessonCommand(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length < 2) {
    context.log('Usage: doc lesson <draft|edit|approve|reject|show|brief> ...');
    return 2;
  }
  try {
    return switch (rest[1]) {
      'draft' => await _draft(context),
      'edit' => await _edit(context),
      'approve' => await _approve(context),
      'reject' => await _reject(context),
      'show' => await _show(context),
      'brief' => await _briefCommand(context),
      _ => () {
        context.log('Unknown lesson command "${rest[1]}".');
        return 2;
      }(),
    };
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  } on FileSystemException catch (error) {
    context.log(
      '${error.message}${error.path == null ? '' : ': ${error.path}'}',
    );
    return 1;
  }
}

/// `doc lessons [--files ...]` and `doc lessons path`.
Future<int> runLessonsCommand(DocContext context) async {
  try {
    final workspace = await _workspace(context);
    final store = _store(context, workspace);
    if (context.args.rest.length > 1 && context.args.rest[1] == 'path') {
      context.out
        ..writeln('Workspace: ${workspace.root} (${workspace.fingerprint})')
        ..writeln('Lessons: ${store.library.path}')
        ..writeln('Drafts: ${store.drafts.path}');
      return 0;
    }
    final filter = {
      for (final file in _files(context)) ?normalizeWorkspacePath(file),
    };
    final lessons = [
      for (final lesson in store.approved())
        if (filter.isEmpty || lesson.files.any(filter.contains)) lesson,
    ];
    context.out.writeln(
      'Lessons: ${lessons.length}${filter.isEmpty ? '' : ' covering ${filter.join(', ')}'}',
    );
    for (final lesson in lessons) {
      context.out.writeln(
        '${lesson.id}  ${lesson.created.toIso8601String().substring(0, 10)}  ${lesson.title}  [${lesson.files.join(', ')}]',
      );
    }
    final drafts = store.pendingDrafts();
    if (drafts.isNotEmpty) {
      context.out.writeln(
        'Drafts waiting for approval (not matched): ${drafts.map((lesson) => lesson.id).join(', ')}',
      );
    }
    return 0;
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
}

Future<int> _draft(DocContext context) async {
  final rest = context.args.rest;
  final lastRestore = context.args['last-restore'] as bool;
  if (lastRestore ? rest.length != 2 : rest.length != 3) {
    context.log(
      'Usage: doc lesson draft <checkpoint-id> [--note "..."] | doc lesson draft --last-restore [--note "..."]',
    );
    return 2;
  }
  String id;
  if (lastRestore) {
    final workspace = await _workspace(context);
    final found = await findLastRestore(workspace.dmc, context.workspace);
    if (found == null) {
      context.log(
        'No applied checkpoint restore was found in this workspace (dmc checkpoint list).',
      );
      return 1;
    }
    id = found.checkpointId;
    context.out.writeln(
      'Last restore: operation ${found.operationId} restored checkpoint $id.',
    );
  } else {
    id = rest[2];
  }
  return draftLesson(context, id, note: context.args['note'] as String?);
}

/// The most recent applied restore that no later redo undid.
class LastRestore {
  final String checkpointId;
  final String operationId;
  final int completedAt;

  const LastRestore(this.checkpointId, this.operationId, this.completedAt);
}

/// Find the most recent completed `restore` operation through dmc's machine
/// schema 1 (`checkpoint list` carries each checkpoint's operations with
/// direction, status and timestamps), skipping a checkpoint whose restore a
/// later redo reapplied. Looks at the 1000 newest checkpoints.
Future<LastRestore?> findLastRestore(DmcClient dmc, String workspace) async {
  final listed = await dmc.runJson([
    'checkpoint',
    'list',
    '--limit',
    '1000',
  ], workspace: workspace);
  if (listed['ok'] != true) {
    throw DmcException('dmc checkpoint list failed: ${_errors(listed)}');
  }
  LastRestore? best;
  for (final checkpoint
      in ((listed['data'] as Map)['checkpoints'] as List).whereType<Map>()) {
    final operations = (checkpoint['operations'] as List? ?? const [])
        .whereType<Map>()
        .where((operation) => operation['status'] == 'completed')
        .toList();
    int completed(Map operation) =>
        (operation['completedAt'] as num?)?.toInt() ?? 0;
    final restores = operations.where((o) => o['direction'] == 'restore');
    if (restores.isEmpty) continue;
    final latest = restores.reduce(
      (a, b) => completed(a) >= completed(b) ? a : b,
    );
    final redoneAfter = operations.any(
      (o) => o['direction'] == 'redo' && completed(o) > completed(latest),
    );
    if (redoneAfter) continue;
    if (best == null || completed(latest) > best.completedAt) {
      best = LastRestore(
        checkpoint['id'] as String,
        latest['id'] as String,
        completed(latest),
      );
    }
  }
  return best;
}

/// Draft a lesson from checkpoint [id]: dmc's facts plus the diff of the
/// work it recorded (what a restore undoes), redacted, go to the workhorse
/// role. `files` always comes from the checkpoint manifest.
Future<int> draftLesson(DocContext context, String id, {String? note}) async {
  final workspace = await _workspace(context);
  final show = await workspace.dmc.runJson([
    'checkpoint',
    'show',
    id,
  ], workspace: context.workspace);
  final diff = await workspace.dmc.runJson([
    'checkpoint',
    'diff',
    id,
  ], workspace: context.workspace);
  for (final envelope in [show, diff]) {
    if (envelope['ok'] != true) {
      context.log('dmc ${envelope['command']} failed: ${_errors(envelope)}');
      return 1;
    }
  }
  // Files come from the checkpoint manifest, never from the model.
  final changed = [
    for (final file
        in ((diff['data'] as Map)['files'] as List).whereType<Map>())
      if ((file['change'] != null && file['change'] != 'unchanged') ||
          file['scope'] != null)
        if (normalizeWorkspacePath(file['path'] as String) case final path?)
          (path: path, change: (file['scope'] ?? file['change']) as String),
  ];
  final files = [for (final file in changed) file.path];
  if (files.isEmpty) {
    context.log(
      'Checkpoint $id changed no files, so there is nothing to learn from it.',
    );
    return 1;
  }
  final checkpoint = ((show['data'] as Map)['checkpoint'] as Map);
  final operations = ((show['data'] as Map)['operations'] as List? ?? const [])
      .whereType<Map>()
      .where((operation) => operation['status'] == 'completed')
      .map((operation) => operation['direction'])
      .toList();
  final undone = await abandonedDiff(
    workspace.dmc,
    workspace: context.workspace,
    checkpointId: id,
    files: changed,
    note: context.log,
  );
  final messages = [
    const ChatMessage('system', draftSystemPrompt),
    ChatMessage(
      'user',
      [
        checkpointFacts(show, diff),
        if (operations.isNotEmpty)
          'Completed operations on this checkpoint: ${operations.join(', ')} (a restore means the change was rolled back).',
        if (note != null && note.trim().isNotEmpty) 'User note: ${note.trim()}',
        if (undone != null && undone.isNotEmpty) ...[
          '',
          'The work this checkpoint recorded (a restore undoes it), as a diff from before to after:',
          undone,
        ],
      ].join('\n'),
    ),
  ];
  if (context.args['show-prompt'] as bool) {
    return _printPrepared(context, 'workhorse', messages);
  }
  final route = context.router.resolve('workhorse');
  final RoleCallResultView call;
  try {
    call = RoleCallResultView(
      await context.router.call(
        'workhorse',
        messages,
        maxTokens: lessonMaxTokens,
      ),
    );
  } on ModelCallException catch (error) {
    context.log(
      explainFailure(
        error,
        context.config.providers[error.provider] ?? route.provider,
        role: 'workhorse',
        localOnly: context.router.localOnly,
      ),
    );
    return 1;
  }
  final parsed = _parseDraft(call.content);
  // Redact what is saved too: the model or the note could echo a secret.
  final redactor = context.router.redactor;
  final title = redactor.redact(parsed.title);
  final body = redactor.redact(parsed.body);
  final agent = checkpoint['agent'];
  final created = DateTime.now().toUtc();
  final lesson = Lesson(
    id: LessonStore.newId(title.text, created),
    title: title.text,
    files: files,
    created: created,
    source: LessonSource(
      checkpoint: id,
      agent: agent is Map ? agent['name'] as String? : null,
      session: agent is Map ? agent['sessionId'] as String? : null,
    ),
    status: 'draft',
    body: body.text,
  );
  final store = _store(context, workspace);
  final file = store.saveDraft(lesson);
  context.out
    ..writeln(file.readAsStringSync())
    ..writeln('Draft saved: ${file.path}')
    ..writeln(
      '(${call.footer}; ${call.redactions + title.count + body.count} item(s) redacted)',
    )
    ..writeln(
      'Review it with "doc lesson edit ${lesson.id}", then "doc lesson approve ${lesson.id}" or "doc lesson reject ${lesson.id}".',
    );
  return 0;
}

({String title, String body}) _parseDraft(String content) {
  final lines = content.trim().split('\n');
  final first = lines.isEmpty ? '' : lines.first.trim();
  final titleMatch = RegExp(
    r'^\**\s*Title:\s*(.+?)\s*\**$',
    caseSensitive: false,
  ).firstMatch(first);
  if (titleMatch == null) {
    return (title: 'Lesson from a checkpoint', body: content.trim());
  }
  return (
    title: titleMatch[1]!.replaceAll(RegExp(r'^["*]+|["*]+$'), '').trim(),
    body: lines.skip(1).join('\n').trim(),
  );
}

Future<int> _edit(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3) {
    context.log('Usage: doc lesson edit <draft>');
    return 2;
  }
  final store = _store(context, await _workspace(context));
  final file = store.resolveDraft(rest[2]);
  final editor = (context.env['VISUAL'] ?? context.env['EDITOR'] ?? 'vi')
      .trim();
  final parts = editor.split(RegExp(r'\s+'));
  final process = await Process.start(parts.first, [
    ...parts.skip(1),
    file.path,
  ], mode: ProcessStartMode.inheritStdio);
  final code = await process.exitCode;
  try {
    final problems = Lesson.parse(file.readAsStringSync()).problems();
    if (problems.isNotEmpty) {
      context.log(
        'The draft still needs work before approval: ${problems.join('; ')}.',
      );
    }
  } on FormatException catch (error) {
    context.log('The draft no longer parses: ${error.message}');
  }
  return code;
}

Future<int> _approve(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3) {
    context.log('Usage: doc lesson approve <draft>');
    return 2;
  }
  final store = _store(context, await _workspace(context));
  final file = store.resolveDraft(rest[2]);
  final Lesson lesson;
  try {
    lesson = Lesson.parse(file.readAsStringSync());
  } on FormatException catch (error) {
    context.log('Not approved: ${error.message}');
    return 1;
  }
  final problems = lesson.problems();
  // An edit could have added a secret; the library never holds one.
  final secrets = context.router.redactor.redact(
    '${lesson.title}\n${lesson.body}',
  );
  if (secrets.count > 0) {
    problems.add(
      'it contains what looks like a secret (${secrets.byKind.keys.join(', ')})',
    );
  }
  if (problems.isNotEmpty) {
    context.log('Not approved: ${problems.join('; ')}.');
    return 1;
  }
  final approved = lesson.withStatus('approved');
  final target = store.libraryFile(approved.id);
  if (target.existsSync()) {
    context.log('Not approved: the library already has ${approved.id}.');
    return 1;
  }
  store.library.createSync(recursive: true);
  target.writeAsStringSync(approved.toMarkdown());
  file.deleteSync();
  context.out.writeln('Approved ${approved.id}: ${target.path}');
  return 0;
}

Future<int> _reject(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3) {
    context.log('Usage: doc lesson reject <draft>');
    return 2;
  }
  final store = _store(context, await _workspace(context));
  final file = store.resolveDraft(rest[2]);
  file.deleteSync();
  context.out.writeln(
    'Rejected and deleted the draft ${p.basename(file.path)}.',
  );
  return 0;
}

Future<int> _show(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3) {
    context.log('Usage: doc lesson show <id>');
    return 2;
  }
  final store = _store(context, await _workspace(context));
  final file = store.libraryFile(rest[2]);
  if (!file.existsSync()) {
    context.log('No approved lesson "${rest[2]}" in ${store.library.path}.');
    return 1;
  }
  context.out.write(file.readAsStringSync());
  return 0;
}

/// The result of matching a task against the library.
class BriefResult {
  final List<LessonMatch> matches;
  final Set<String> candidates;
  final String? brief;
  final String? footer;

  const BriefResult(this.matches, this.candidates, {this.brief, this.footer});
}

/// Match [task] against the library (a fixed rule, no model) and, when
/// lessons match, ask the summary role for a brief. Returns null when the
/// call failed (already reported).
Future<BriefResult?> buildBrief(DocContext context, String task) async {
  final workspace = await _workspace(context);
  final store = _store(context, workspace);
  final lessons = store.approved();
  final known = await _knownFiles(context, workspace, lessons);
  final candidates = candidateFiles(task, known, extraFiles: _files(context));
  final matches = matchLessons(lessons, candidates);
  if (matches.isEmpty) return BriefResult(matches, candidates);
  final messages = [
    const ChatMessage('system', briefSystemPrompt),
    ChatMessage(
      'user',
      [
        'Task: $task',
        for (final match in matches) ...[
          '',
          'Lesson: ${match.lesson.title}',
          'Files: ${match.lesson.files.join(', ')}',
          match.lesson.body,
        ],
      ].join('\n'),
    ),
  ];
  if (context.args['show-prompt'] as bool) {
    _printPrepared(context, 'summary', messages);
    return BriefResult(matches, candidates);
  }
  final route = context.router.resolve('summary');
  try {
    final call = RoleCallResultView(
      await context.router.call(
        'summary',
        messages,
        maxTokens: lessonMaxTokens,
      ),
    );
    return BriefResult(
      matches,
      candidates,
      brief: _limitWords(_asBrief(call.content), 100),
      footer: '${call.footer}; ${call.redactions} item(s) redacted',
    );
  } on ModelCallException catch (error) {
    context.log(
      explainFailure(
        error,
        context.config.providers[error.provider] ?? route.provider,
        role: 'summary',
        localOnly: context.router.localOnly,
      ),
    );
    return null;
  }
}

String _asBrief(String text) {
  final trimmed = text.trim();
  return trimmed.toLowerCase().startsWith('before you start')
      ? trimmed
      : 'Before you start: $trimmed';
}

String _limitWords(String text, int limit) {
  final words = text.split(RegExp(r'\s+'));
  return words.length <= limit ? text : '${words.take(limit).join(' ')}…';
}

/// Files dmc knows in the workspace: the latest checkpoint's manifest, plus
/// lesson files that still exist. Doc never lists or reads workspace files
/// itself; it checks existence only.
Future<Set<String>> _knownFiles(
  DocContext context,
  _Workspace workspace,
  List<Lesson> lessons,
) async {
  final known = <String>{};
  final listed = await workspace.dmc.runJson([
    'checkpoint',
    'list',
    '--limit',
    '1',
  ], workspace: context.workspace);
  final checkpoints =
      ((listed['data'] as Map?)?['checkpoints'] as List?) ?? const [];
  if (checkpoints.isNotEmpty) {
    final id = (checkpoints.first as Map)['id'] as String;
    final show = await workspace.dmc.runJson([
      'checkpoint',
      'show',
      id,
    ], workspace: context.workspace);
    for (final file
        in ((show['data'] as Map?)?['files'] as List?) ?? const []) {
      if (file is Map) {
        final path = normalizeWorkspacePath(file['path'] as String);
        if (path != null) known.add(path);
      }
    }
  }
  for (final lesson in lessons) {
    for (final file in lesson.files) {
      if (File(p.joinAll([workspace.root, ...file.split('/')])).existsSync()) {
        known.add(file);
      }
    }
  }
  return known;
}

void _printMatches(DocContext context, BriefResult result) {
  context.out.writeln(
    'Matched ${result.matches.length} lesson(s) on ${result.candidates.isEmpty ? 'no files' : result.candidates.join(', ')}:',
  );
  for (final match in result.matches) {
    context.out.writeln(
      '- ${match.lesson.id} (score ${match.score}: ${match.matchedFiles.join(', ')}) ${match.lesson.title}',
    );
  }
}

Future<int> _briefCommand(DocContext context) async {
  final task = context.args['task'] as String?;
  if (task == null || task.trim().isEmpty) {
    context.log('Usage: doc lesson brief --task "<text>" [--files <path>...]');
    return 2;
  }
  final result = await buildBrief(context, task);
  if (result == null) return 1;
  if (result.matches.isEmpty) {
    context.out.writeln(
      'No lessons match ${result.candidates.isEmpty ? 'this task (no known files named)' : result.candidates.join(', ')}. No model was called.',
    );
    return 0;
  }
  if (result.brief == null) return 0; // --show-prompt
  context.out
    ..writeln(result.brief)
    ..writeln('');
  _printMatches(context, result);
  context.out.writeln('(${result.footer})');
  return 0;
}

/// `doc start <muse-code|claude-code> "<task>" [--files ...] [--yes]`
Future<int> runStartCommand(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 3 || !{'muse-code', 'claude-code'}.contains(rest[1])) {
    context.log(
      'Usage: doc start <muse-code|claude-code> "<task>" [--files <path>...] [--yes]',
    );
    return 2;
  }
  final agent = rest[1];
  final task = rest[2];
  final BriefResult? result;
  try {
    result = await buildBrief(context, task);
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
  if (result == null) return 1;
  var accepted = false;
  if (result.matches.isEmpty) {
    context.out.writeln(
      'No lessons match this task. Starting $agent with the task alone.',
    );
  } else if (result.brief == null) {
    return 0; // --show-prompt
  } else {
    context.out
      ..writeln(result.brief)
      ..writeln('');
    _printMatches(context, result);
    if (context.args['yes'] as bool) {
      accepted = true;
      context.out.writeln('Adding the brief to the first prompt (--yes).');
    } else {
      context.out.write("Add this to the agent's first prompt? [y/N] ");
      final answer = (context.readLine() ?? '').trim().toLowerCase();
      accepted = answer == 'y' || answer == 'yes';
    }
  }
  final prompt = composeFirstPrompt(
    task: task,
    brief: result.brief,
    accepted: accepted,
  );
  final binary = agent == 'muse-code'
      ? (context.env['DOC_MUSE_BIN'] ?? 'muse')
      : (context.env['DOC_CLAUDE_BIN'] ?? 'claude');
  context.out.writeln('Starting $agent${accepted ? ' with the brief' : ''}.');
  try {
    // Both agents take the first prompt as their only argument in
    // interactive mode: `muse "<prompt>"`, `claude "<prompt>"`. Their own
    // hooks create the checkpoints.
    final process = await Process.start(
      binary,
      [prompt],
      workingDirectory: context.workspace,
      mode: ProcessStartMode.inheritStdio,
    );
    return await process.exitCode;
  } on ProcessException catch (error) {
    context.log('Could not start $binary: ${error.message}');
    return 1;
  }
}

int _printPrepared(
  DocContext context,
  String role,
  List<ChatMessage> messages,
) {
  final prepared = context.router.prepare(
    role,
    messages,
    maxTokens: lessonMaxTokens,
  );
  context.out
    ..writeln(
      'Would send to ${prepared.route.provider.id} (${prepared.route.model}). Nothing was sent.',
    )
    ..writeln('Redacted: ${prepared.redactionCount} item(s)')
    ..writeln(const JsonEncoder.withIndent('  ').convert(prepared.body));
  return 0;
}

/// A role call's answer and its one-line footer.
class RoleCallResultView {
  final String content;
  final String footer;
  final int redactions;

  RoleCallResultView(RoleCallResult call)
    : content = call.result.content,
      redactions = call.redactionCount,
      footer =
          '${call.result.provider} ${call.result.model}; ${call.result.promptTokens} in / '
          '${call.result.completionTokens} out; ${call.result.latency.inMilliseconds} ms'
          '${call.fellBackFrom == null ? '' : '; fell back from ${call.fellBackFrom}'}';
}
