import 'cli.dart';
import 'dmc_client.dart';
import 'lesson_commands.dart';

/// `doc restore <checkpoint-id> [--yes] [--no-lesson]`
///
/// Rollback without amnesia: preview dmc's checkpoint restore in plain
/// terms, apply it only after the user says yes, then offer to draft a
/// lesson from the work that was undone. Every file change goes through
/// dmc's preview-first, journaled restore; Doc never writes workspace files
/// and never forces a conflicting or interrupted restore. `--yes` answers
/// yes to both questions and is meant only for scripted demos.
Future<int> runRestoreCommand(DocContext context) async {
  final rest = context.args.rest;
  if (rest.length != 2) {
    context.log('Usage: doc restore <checkpoint-id> [--yes] [--no-lesson]');
    return 2;
  }
  final id = rest[1];
  final yes = context.args['yes'] as bool;
  final DmcClient dmc;
  try {
    dmc = await context.dmc();
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
  final out = context.out;

  final show = await dmc.runJson([
    'checkpoint',
    'show',
    id,
  ], workspace: context.workspace);
  final checkpoint = (show['data'] as Map?)?['checkpoint'];
  if (checkpoint is Map) {
    final agent = checkpoint['agent'];
    out.writeln(
      'Checkpoint $id (${checkpoint['status']}${agent is Map ? ', ${agent['name']} turn' : ''}): ${checkpoint['label'] ?? '(no label)'}',
    );
  }

  final preview = await dmc.runJson([
    'checkpoint',
    'restore',
    id,
  ], workspace: context.workspace);
  final data = (preview['data'] as Map?) ?? const {};
  final actions = (data['actions'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final skipped = (data['skipped'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final conflicts = [
    ...(data['conflicts'] as List? ?? const []).whereType<Map>(),
    ...(data['dataErrors'] as List? ?? const []).whereType<Map>(),
  ];

  if (actions.isNotEmpty) {
    out.writeln('Restore would change ${actions.length} file(s):');
    for (final action in actions) {
      out.writeln('  - ${action['path']}: ${describeRestoreAction(action)}');
    }
  }
  if (skipped.isNotEmpty) {
    out.writeln(
      'Left alone (protection changed during the turn; never written):',
    );
    for (final item in skipped) {
      out.writeln('  - ${item['path']}: ${item['code']}');
    }
  }
  if (data['canApply'] != true || preview['ok'] != true) {
    if (conflicts.isNotEmpty) {
      out.writeln('dmc will not restore this checkpoint as it stands:');
      for (final conflict in conflicts) {
        out.writeln(
          '  - ${conflict['path'] ?? '(checkpoint)'}: ${conflict['code']}: ${conflict['message']}',
        );
      }
    }
    for (final error
        in (preview['errors'] as List? ?? const []).whereType<Map>()) {
      if (conflicts.any(
        (c) => c['code'] == error['code'] && c['path'] == error['path'],
      )) {
        continue;
      }
      out.writeln('  - ${error['code']}: ${error['message']}');
    }
    out.writeln(
      'Nothing was changed. Resolve the conflicts (for example, save or undo your later edits) and run doc restore again; Doc never forces a restore.',
    );
    return (preview['exitCode'] as num?)?.toInt() ?? 4;
  }
  if (actions.isEmpty) {
    out.writeln(
      'Nothing to restore: the workspace already matches the state before the turn.',
    );
    return 0;
  }

  if (!_ask(
    context,
    'Restore these files? [y/N] ',
    yes: yes,
    byDefault: false,
  )) {
    out.writeln('Nothing was changed.');
    return 0;
  }
  final applied = await dmc.runJson([
    'checkpoint',
    'restore',
    id,
    '--apply',
  ], workspace: context.workspace);
  final appliedData = (applied['data'] as Map?) ?? const {};
  if (applied['ok'] != true) {
    out.writeln('dmc did not complete the restore:');
    for (final error
        in (applied['errors'] as List? ?? const []).whereType<Map>()) {
      out.writeln(
        '  - ${error['path'] == null ? '' : '${error['path']}: '}${error['code']}: ${error['message']}',
      );
    }
    final operation = appliedData['operationId'];
    if ((applied['exitCode'] as num?)?.toInt() == 6 && operation != null) {
      out.writeln(
        'The restore was interrupted. Recover with: dmc checkpoint recover $operation --resume (or --rollback). Doc does not recover it for you.',
      );
    }
    return (applied['exitCode'] as num?)?.toInt() ?? 1;
  }
  out.writeln(
    appliedData['noOp'] == true
        ? 'Nothing needed restoring.'
        : 'Restored ${actions.length} file(s) through dmc (operation ${appliedData['operationId']}).',
  );

  if (context.args['no-lesson'] as bool) return 0;
  if (!_ask(
    context,
    'Draft a lesson from the work you just undid? [Y/n] ',
    yes: yes,
    byDefault: true,
  )) {
    out.writeln('No lesson drafted. You can still run: doc lesson draft $id');
    return 0;
  }
  // Only the person who undid the work knows why; ask once (optional).
  var note = context.args['note'] as String?;
  if (note == null && !yes) {
    out.write('What went wrong? (optional, press Enter to skip) ');
    final answer = context.readLine()?.trim();
    if (answer != null && answer.isNotEmpty) note = answer;
  }
  // The restore itself succeeded: a failed draft is reported on stderr and
  // does not change the exit code.
  await draftLesson(context, id, note: note);
  return 0;
}

/// A restore action in plain words.
String describeRestoreAction(Map action) {
  final expected = (action['expected'] as Map?)?['kind'];
  final intended = (action['intended'] as Map?)?['kind'];
  if (intended == 'absent') return 'delete it (the turn created it)';
  if (expected == 'absent') return 'recreate it (the turn deleted it)';
  return 'put back the version from before the turn';
}

bool _ask(
  DocContext context,
  String question, {
  required bool yes,
  required bool byDefault,
}) {
  if (yes) {
    context.out.writeln('$question${'yes (--yes)'}');
    return true;
  }
  context.out.write(question);
  final answer = (context.readLine() ?? '').trim().toLowerCase();
  if (answer.isEmpty) return byDefault;
  return answer == 'y' || answer == 'yes';
}
