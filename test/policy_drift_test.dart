import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Ignore-policy drift during a checkpoint is handled per file: close
/// succeeds, files whose protection changed are recorded as left_scope or
/// entered_scope, and restore and redo never write them.
void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;

  Future<void> git(List<String> args) async {
    final result = await Process.run('git', [
      '-c',
      'core.autocrlf=false',
      ...args,
    ], workingDirectory: root.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  File file(String relative) =>
      File(p.joinAll([root.path, ...relative.split('/')]));

  void write(String relative, String contents) => file(relative)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  String? read(String relative) =>
      file(relative).existsSync() ? file(relative).readAsStringSync() : null;

  CheckpointService service() =>
      CheckpointService(basePath: root.path, homePath: home.path);
  CheckpointRestoreService restorer() =>
      CheckpointRestoreService(basePath: root.path);

  Future<String> begin() async {
    final result = await service().begin(source: 'test');
    expect(result.exitCode, 0, reason: result.encode());
    return (result.data['checkpoint'] as Map)['id'] as String;
  }

  Future<CommandResult> close(String id) async {
    final result = await service().close(id);
    expect(result.exitCode, 0, reason: result.encode());
    return result;
  }

  /// path → scope (or change, when the scope did not change).
  Future<Map<String, String?>> manifest(String id) async {
    final shown = await service().show(id);
    return {
      for (final entry in (shown.data['files'] as List).cast<Map>())
        entry['path'] as String: (entry['scope'] ?? entry['change']) as String?,
    };
  }

  Map<String, String> skippedOf(CommandResult plan) => {
    for (final item in (plan.data['skipped'] as List).cast<Map>())
      item['path'] as String: item['code'] as String,
  };

  Set<String> actionPaths(CommandResult plan) => {
    for (final item in (plan.data['actions'] as List).cast<Map>())
      item['path'] as String,
  };

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('dmc_policy_drift_');
    root = Directory(p.join(sandbox.path, 'drift repo ü'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  group('in a Git work tree', () {
    setUp(() async {
      await git(['init', '-q', '.']);
      await initDmc(basePath: root.path);
    });

    test('an added ignore line makes an existing file left_scope', () async {
      write('.gitignore', '*.log\n');
      write('notes.txt', 'notes before');
      write('other.txt', 'other before');
      final id = await begin();
      // The agent ignores notes.txt, then keeps editing it and other files.
      write('.gitignore', '*.log\nnotes.txt\n');
      write('notes.txt', 'notes after');
      write('other.txt', 'other after');
      final closed = await close(id);
      final summary = closed.data['checkpoint'] as Map;
      expect(summary['status'], 'closed');
      expect(
        summary['closePolicyFingerprint'],
        isNot(summary['policyFingerprint']),
      );
      expect(
        closed.warnings.where((warning) => warning.code == 'policy_changed'),
        hasLength(1),
      );
      expect(await manifest(id), {
        '.gitignore': 'modified',
        'notes.txt': 'left_scope',
        'other.txt': 'modified',
      });
      final shown = await service().show(id);
      final notes = (shown.data['files'] as List).cast<Map>().singleWhere(
        (entry) => entry['path'] == 'notes.txt',
      );
      expect((notes['before'] as Map)['kind'], 'file');
      expect(notes['after'], isNull);
      expect(notes['change'], isNull);
      expect(
        checkpointHumanLines(shown),
        contains(startsWith('notes.txt: left scope')),
      );

      final preview = await restorer().restore(id);
      expect(preview.exitCode, 0, reason: preview.encode());
      expect(preview.data['canApply'], isTrue);
      expect(skippedOf(preview), {'notes.txt': 'left_scope'});
      expect(actionPaths(preview), {'.gitignore', 'other.txt'});
      expect(
        checkpointOperationHumanLines(preview),
        contains('  left_scope: notes.txt'),
      );

      final applied = await restorer().restore(id, apply: true);
      expect(applied.exitCode, 0, reason: applied.encode());
      expect(read('.gitignore'), '*.log\n');
      expect(read('other.txt'), 'other before');
      expect(read('notes.txt'), 'notes after');
    });

    test(
      'a removed ignore line makes a file entered_scope; redo checks it',
      () async {
        write('.gitignore', '*.log\n');
        write('app.txt', 'app before');
        write('debug.log', 'log at begin');
        final id = await begin();
        write('.gitignore', '');
        write('debug.log', 'log at close');
        write('app.txt', 'app after');
        await close(id);
        expect(await manifest(id), {
          '.gitignore': 'modified',
          'app.txt': 'modified',
          'debug.log': 'entered_scope',
        });

        final preview = await restorer().restore(id);
        expect(skippedOf(preview), {'debug.log': 'entered_scope'});
        final restored = await restorer().restore(id, apply: true);
        expect(restored.exitCode, 0, reason: restored.encode());
        expect(read('.gitignore'), '*.log\n');
        expect(read('app.txt'), 'app before');
        // Never deleted or overwritten by restore.
        expect(read('debug.log'), 'log at close');

        // Redo with the working file still at its recorded after state.
        final redo = await restorer().redo(id, apply: true);
        expect(redo.exitCode, 0, reason: redo.encode());
        expect(skippedOf(redo), {'debug.log': 'entered_scope'});
        expect(read('.gitignore'), '');
        expect(read('app.txt'), 'app after');
        expect(read('debug.log'), 'log at close');
      },
    );

    test(
      'redo refuses an entered_scope file that changed since close',
      () async {
        write('.gitignore', '*.log\n');
        write('app.txt', 'app before');
        write('debug.log', 'log at begin');
        final id = await begin();
        write('.gitignore', '');
        write('debug.log', 'log at close');
        write('app.txt', 'app after');
        await close(id);
        expect((await restorer().restore(id, apply: true)).exitCode, 0);
        write('debug.log', 'edited after the restore');

        final redo = await restorer().redo(id, apply: true);
        expect(redo.exitCode, 4, reason: redo.encode());
        expect(
          ((redo.data['conflicts'] as List).single as Map)['path'],
          'debug.log',
        );
        // Nothing was written.
        expect(read('debug.log'), 'edited after the restore');
        expect(read('app.txt'), 'app before');
        expect(read('.gitignore'), '*.log\n');
      },
    );

    test('a new nested .gitignore makes files left_scope', () async {
      write('sub/a.txt', 'a before');
      write('sub/b.txt', 'b before');
      final id = await begin();
      write('sub/.gitignore', 'b.txt\n');
      write('sub/a.txt', 'a after');
      write('sub/b.txt', 'b after');
      await close(id);
      final a = p.join('sub', 'a.txt');
      final b = p.join('sub', 'b.txt');
      final ignore = p.join('sub', '.gitignore');
      expect(await manifest(id), {
        ignore: 'created',
        a: 'modified',
        b: 'left_scope',
      });

      final preview = await restorer().restore(id);
      expect(skippedOf(preview), {b: 'left_scope'});
      expect(actionPaths(preview), {ignore, a});
      final applied = await restorer().restore(id, apply: true);
      expect(applied.exitCode, 0, reason: applied.encode());
      expect(read('sub/.gitignore'), isNull);
      expect(read('sub/a.txt'), 'a before');
      expect(read('sub/b.txt'), 'b after');
    });
  });

  test('.dmcignore edited mid-turn outside Git', () async {
    await initDmc(basePath: root.path);
    write('.dmcignore', 'generated/\n');
    write('generated/model.txt', 'generated at begin');
    write('secret.txt', 'secret before');
    write('gone.txt', 'gone before');
    write('plain.txt', 'plain before');
    final id = await begin();
    // Stop ignoring generated/, start ignoring secret.txt and gone.txt.
    write('.dmcignore', 'secret.txt\ngone.txt\n');
    write('secret.txt', 'secret after');
    file('gone.txt').deleteSync();
    write('plain.txt', 'plain after');
    await close(id);
    final model = p.join('generated', 'model.txt');
    expect(await manifest(id), {
      '.dmcignore': 'modified',
      model: 'entered_scope',
      'gone.txt': 'left_scope',
      'plain.txt': 'modified',
      'secret.txt': 'left_scope',
    });

    final preview = await restorer().restore(id);
    expect(preview.data['canApply'], isTrue);
    expect(skippedOf(preview), {
      model: 'entered_scope',
      'gone.txt': 'left_scope',
      'secret.txt': 'left_scope',
    });
    final applied = await restorer().restore(id, apply: true);
    expect(applied.exitCode, 0, reason: applied.encode());
    expect(read('.dmcignore'), 'generated/\n');
    expect(read('plain.txt'), 'plain before');
    // Byte-identical: not restored, not recreated, not deleted.
    expect(read('secret.txt'), 'secret after');
    expect(read('gone.txt'), isNull);
    expect(read('generated/model.txt'), 'generated at begin');
  });

  test('an unchanged policy records no drift and no scope changes', () async {
    await initDmc(basePath: root.path);
    write('a.txt', 'a');
    final id = await begin();
    write('a.txt', 'b');
    final closed = await close(id);
    final summary = closed.data['checkpoint'] as Map;
    expect(summary['closePolicyFingerprint'], summary['policyFingerprint']);
    expect(
      closed.warnings.map((warning) => warning.code),
      isNot(contains('policy_changed')),
    );
    expect(await manifest(id), {'a.txt': 'modified'});
    expect(skippedOf(await restorer().restore(id)), isEmpty);
  });
}
