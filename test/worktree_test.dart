import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Each Git worktree has its own dmc vault: an agent hook never records a
/// turn from one work tree in another's vault, and checkpoints in different
/// worktrees are independent.
void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;
  late List<String> warnings;

  Future<void> git(List<String> args, {required String cwd}) async {
    final result = await Process.run('git', [
      '-c',
      'user.name=dmc test',
      '-c',
      'user.email=dmc@example.invalid',
      '-c',
      'protocol.file.allow=always',
      '-c',
      'core.autocrlf=false',
      ...args,
    ], workingDirectory: cwd);
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')}: ${result.stderr}',
    );
  }

  void write(String directory, String relative, String contents) =>
      File(p.joinAll([directory, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  String read(String directory, String relative) =>
      File(p.joinAll([directory, ...relative.split('/')])).readAsStringSync();

  /// A Muse Code hook call from [cwd] for [session].
  Future<void> hook(
    String event,
    String cwd, {
    required String session,
    String turn = 'turn-1',
  }) =>
      AgentHookRunner(
        environment: const {},
        currentDirectory: () => cwd,
        serviceFactory: (rootPath) =>
            CheckpointService(basePath: rootPath, homePath: home.path),
        warn: warnings.add,
      ).run(
        ['muse-code', event],
        stdinText: jsonEncode({
          'hook_event_name': event,
          'session_id': session,
          'turn_id': turn,
          'cwd': cwd,
          'transcript_path': null,
          if (event == 'UserPromptSubmit') 'prompt': 'edit in $session',
        }),
      );

  List<CheckpointRecord> checkpoints(String workspace) {
    final database = DmcDatabase(DmcPaths(basePath: workspace).dbPath)
      ..initialize();
    try {
      return CheckpointRepository(database).listCheckpoints();
    } finally {
      database.close();
    }
  }

  Future<String> addWorktree(String name) async {
    final path = p.join(root.path, '.worktrees', name);
    await git(['worktree', 'add', '-q', '-b', name, path], cwd: root.path);
    return path;
  }

  Future<List<String>> printed(Future<void> Function() action) async {
    final output = <String>[];
    await runZoned(
      action,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => output.add(message),
      ),
    );
    return output;
  }

  setUp(() async {
    warnings = [];
    sandbox = Directory.systemTemp.createTempSync('dmc_worktree_');
    root = Directory(p.join(sandbox.path, 'main repo'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
    await git(['init', '-q', '.'], cwd: root.path);
    write(root.path, 'app.txt', 'app v1');
    await git(['add', 'app.txt'], cwd: root.path);
    await git(['commit', '-q', '-m', 'init'], cwd: root.path);
    // Muse Code keeps its worktrees inside the repo and excludes them.
    File(
      p.join(root.path, '.git', 'info', 'exclude'),
    ).writeAsStringSync('/.worktrees/\n', mode: FileMode.append);
    await initDmc(basePath: root.path);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'a hook from a linked worktree without a vault records nothing',
    () async {
      final worktree = await addWorktree('session-a');
      await hook('UserPromptSubmit', worktree, session: 'a');
      write(worktree, 'app.txt', 'edited in the worktree');
      await hook('Stop', worktree, session: 'a');
      expect(checkpoints(root.path), isEmpty);
      expect(warnings, hasLength(2));
      expect(warnings.first, contains('belongs to another Git work tree'));
      expect(warnings.first, contains('dmc init'));
    },
  );

  test('after dmc init the worktree uses its own vault', () async {
    final worktree = await addWorktree('session-a');
    await initDmc(basePath: worktree);
    await hook('UserPromptSubmit', worktree, session: 'a');
    write(worktree, 'app.txt', 'edited in the worktree');
    await hook('Stop', worktree, session: 'a');
    expect(warnings, isEmpty);
    expect(checkpoints(root.path), isEmpty);
    final own = checkpoints(worktree);
    expect(own.single.status, CheckpointStatus.closed);
    expect(own.single.source, 'muse-code');
    // A subdirectory of the worktree still belongs to it.
    final nested = p.join(worktree, 'src', 'deep');
    Directory(nested).createSync(recursive: true);
    await hook('UserPromptSubmit', nested, session: 'a', turn: 'turn-2');
    await hook('Stop', nested, session: 'a', turn: 'turn-2');
    expect(checkpoints(worktree), hasLength(2));
    expect(warnings, isEmpty);
  });

  test(
    'two worktrees taking turns get independent, restorable checkpoints',
    () async {
      final a = await addWorktree('session-a');
      final b = await addWorktree('session-b');
      await initDmc(basePath: a);
      await initDmc(basePath: b);

      await hook('UserPromptSubmit', a, session: 'a');
      await hook('UserPromptSubmit', b, session: 'b');
      write(a, 'app.txt', 'approach A');
      write(b, 'app.txt', 'approach B');
      write(b, 'extra.txt', 'only in B');
      await hook('Stop', a, session: 'a');
      await hook('Stop', b, session: 'b');
      expect(warnings, isEmpty);
      expect(checkpoints(root.path), isEmpty);

      final checkpointA = checkpoints(a).single;
      final checkpointB = checkpoints(b).single;
      expect(checkpointA.agent!.sessionId, 'a');
      expect(checkpointB.agent!.sessionId, 'b');
      final filesA =
          (await CheckpointService(
                basePath: a,
                homePath: home.path,
              ).diff(checkpointA.id)).data['files']
              as List;
      final filesB =
          (await CheckpointService(
                basePath: b,
                homePath: home.path,
              ).diff(checkpointB.id)).data['files']
              as List;
      Map<String, Object?> changes(List files) => {
        for (final file in files.cast<Map>())
          if (file['change'] != 'unchanged')
            file['path'] as String: file['change'],
      };
      expect(changes(filesA), {'app.txt': 'modified'});
      expect(changes(filesB), {'app.txt': 'modified', 'extra.txt': 'created'});

      // Restore B only; A and the main work tree are untouched.
      final restoredB = await CheckpointRestoreService(
        basePath: b,
      ).restore(checkpointB.id, apply: true);
      expect(restoredB.exitCode, 0, reason: restoredB.encode());
      expect(read(b, 'app.txt'), 'app v1');
      expect(File(p.join(b, 'extra.txt')).existsSync(), isFalse);
      expect(read(a, 'app.txt'), 'approach A');
      expect(read(root.path, 'app.txt'), 'app v1');

      final restoredA = await CheckpointRestoreService(
        basePath: a,
      ).restore(checkpointA.id, apply: true);
      expect(restoredA.exitCode, 0, reason: restoredA.encode());
      expect(read(a, 'app.txt'), 'app v1');
    },
  );

  test('a nested repository and a submodule are ignored', () async {
    final nested = Directory(p.join(root.path, 'vendor', 'lib'))
      ..createSync(recursive: true);
    await git(['init', '-q', '.'], cwd: nested.path);
    await hook('UserPromptSubmit', nested.path, session: 'n');

    final source = Directory(p.join(sandbox.path, 'source'))..createSync();
    await git(['init', '-q', '.'], cwd: source.path);
    write(source.path, 'lib.txt', 'lib');
    await git(['add', 'lib.txt'], cwd: source.path);
    await git(['commit', '-q', '-m', 'lib'], cwd: source.path);
    await git(['submodule', 'add', '-q', source.path, 'sub'], cwd: root.path);
    final submodule = p.join(root.path, 'sub');
    expect(
      FileSystemEntity.typeSync(p.join(submodule, '.git')),
      FileSystemEntityType.file,
    );
    await hook('UserPromptSubmit', submodule, session: 's');

    expect(checkpoints(root.path), isEmpty);
    expect(warnings, hasLength(2));
    expect(warnings, everyElement(contains('another Git work tree')));

    // The main work tree itself still records turns.
    await hook('UserPromptSubmit', root.path, session: 'main');
    await hook('Stop', root.path, session: 'main');
    expect(checkpoints(root.path).single.status, CheckpointStatus.closed);
    expect(warnings, hasLength(2));
  });

  test('status and doctor report the worktree layout', () async {
    final a = await addWorktree('session-a');
    await addWorktree('session-b');
    await initDmc(basePath: a);
    final canonicalA = Directory(a).resolveSymbolicLinksSync();
    final canonicalRoot = root.resolveSymbolicLinksSync();

    final mainStatus = await printed(
      () => showStatus(basePath: root.path, homePath: home.path),
    );
    expect(
      mainStatus,
      contains('Git worktree: main work tree, 2 linked worktree(s)'),
    );
    expect(
      mainStatus,
      contains('Linked worktree: $canonicalA (own dmc vault)'),
    );
    expect(
      mainStatus,
      contains(allOf(contains('session-b'), contains('no dmc vault'))),
    );

    final worktreeStatus = await printed(
      () => showStatus(basePath: a, homePath: home.path),
    );
    expect(
      worktreeStatus,
      contains('Git worktree: linked worktree of $canonicalRoot'),
    );
    expect(
      worktreeStatus,
      contains(startsWith('Worktree vault: this worktree')),
    );

    final doctor = await printed(() async {
      await runDoctor(basePath: a, homePath: home.path);
    });
    expect(doctor, contains('Git worktree: linked worktree of $canonicalRoot'));

    final info = describeGitWorktree(a)!;
    expect(info.linked, isTrue);
    expect(describeGitWorktree(sandbox.path), isNull);
  });
}
