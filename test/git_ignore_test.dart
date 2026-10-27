import 'dart:async';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Git-mode ignore handling: inside a Git work tree, Git decides what is
/// ignored and DMC's own rules apply on top.
void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;

  Future<String> git(List<String> args, {String? cwd}) async {
    final result = await Process.run(
      'git',
      [
        '-c',
        'user.name=dmc test',
        '-c',
        'user.email=dmc@example.invalid',
        '-c',
        'core.autocrlf=false',
        '-c',
        'protocol.file.allow=always',
        ...args,
      ],
      workingDirectory: cwd ?? root.path,
      environment: {'GIT_CONFIG_NOSYSTEM': '1'},
    );
    expect(
      result.exitCode,
      0,
      reason: 'git ${args.join(' ')}: ${result.stderr}',
    );
    return result.stdout as String;
  }

  File write(String relative, String contents) =>
      File(p.joinAll([root.path, ...relative.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(contents);

  CheckpointService service({GitLocator? gitLocator}) => CheckpointService(
    basePath: root.path,
    homePath: home.path,
    gitLocator: gitLocator,
  );

  ({List<CheckpointFileRecord> files, List<CheckpointIssue> issues}) records(
    String id,
  ) {
    final database = DmcDatabase(DmcPaths(basePath: root.path).dbPath)
      ..initialize();
    try {
      final repository = CheckpointRepository(database);
      return (files: repository.getFiles(id), issues: repository.getIssues(id));
    } finally {
      database.close();
    }
  }

  Future<String> begin() async {
    final result = await service().begin(source: 'test');
    expect(result.exitCode, 0, reason: result.encode());
    return (result.data['checkpoint'] as Map)['id'] as String;
  }

  Future<Set<String>> protectedPaths() async {
    final id = await begin();
    final close = await service().close(id);
    expect(close.exitCode, 0, reason: close.encode());
    return {
      for (final file in records(id).files) p.split(file.filePath).join('/'),
    };
  }

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('dmc_git_ignore_');
    // Spaces and non-ASCII characters keep the path handling honest.
    root = Directory(p.join(sandbox.path, 'my repo ü'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
    await git(['init', '-q', '.']);
    await initDmc(basePath: root.path);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'Git decides: nested .gitignore, negation and a character class',
    () async {
      write('.gitignore', '*.log\n!keep.log\nfile[0-9].txt\n');
      write('app.log', 'ignored');
      write('keep.log', 're-included by negation');
      write('file1.txt', 'ignored by a character class');
      write('fileA.txt', 'not matched by the class');
      write('web/.gitignore', 'dist/\n');
      write('web/dist/bundle.js', 'ignored by the nested .gitignore');
      write('web/src/main.js', 'kept');
      final protected = await protectedPaths();
      expect(
        protected,
        containsAll([
          '.gitignore',
          'keep.log',
          'fileA.txt',
          'web/.gitignore',
          'web/src/main.js',
        ]),
      );
      expect(
        protected.intersection({'app.log', 'file1.txt', 'web/dist/bundle.js'}),
        isEmpty,
      );
      // Paths come back native, relative to the workspace.
      final id = await begin();
      expect(
        records(id).files.map((file) => file.filePath),
        contains(p.join('web', 'src', 'main.js')),
      );
    },
  );

  test('info/exclude applies, and a tracked file stays in scope', () async {
    write('.gitignore', '*.cfg\n');
    write('tracked.cfg', 'tracked before the pattern mattered');
    await git(['add', '-f', 'tracked.cfg']);
    write('local.cfg', 'untracked and ignored');
    write('scratch/notes.txt', 'excluded by info/exclude');
    File(p.join(root.path, '.git', 'info', 'exclude'))
      ..createSync(recursive: true)
      ..writeAsStringSync('scratch/\n');
    final protected = await protectedPaths();
    expect(protected, contains('tracked.cfg'));
    expect(protected, isNot(contains('local.cfg')));
    expect(protected, isNot(contains('scratch/notes.txt')));
  });

  test('submodules and nested repositories are excluded', () async {
    write('top.txt', 'kept');
    final embedded = Directory(p.join(root.path, 'embedded'))..createSync();
    await git(['init', '-q', '.'], cwd: embedded.path);
    File(p.join(embedded.path, 'inner.txt')).writeAsStringSync('inner');
    await git(['add', 'inner.txt'], cwd: embedded.path);
    await git(['commit', '-q', '-m', 'inner'], cwd: embedded.path);
    // Adding the embedded repository records a gitlink, as a submodule does.
    await git(['add', 'embedded']);
    final untracked = Directory(p.join(root.path, 'loose'))..createSync();
    await git(['init', '-q', '.'], cwd: untracked.path);
    File(p.join(untracked.path, 'x.txt')).writeAsStringSync('x');

    final id = await begin();
    final result = records(id);
    final protected = {
      for (final file in result.files) p.split(file.filePath).join('/'),
    };
    expect(protected, contains('top.txt'));
    expect(
      protected.where(
        (path) => path.startsWith('embedded') || path.startsWith('loose'),
      ),
      isEmpty,
    );
    expect(
      result.issues
          .where((issue) => issue.code == 'nested_repository')
          .map((issue) => issue.filePath),
      containsAll(['embedded', 'loose']),
    );
  });

  test('.dmcignore and the default directories apply on top of Git', () async {
    write('.dmcignore', 'generated/\n');
    write('generated/model.dart', 'excluded by .dmcignore');
    write('node_modules/pkg/index.js', 'excluded by a default directory');
    write('lib/main.dart', 'kept');
    await git(['add', '-f', 'node_modules', 'generated']);
    final protected = await protectedPaths();
    expect(protected, containsAll(['lib/main.dart', '.dmcignore']));
    expect(
      protected.where(
        (path) =>
            path.startsWith('generated/') || path.startsWith('node_modules/'),
      ),
      isEmpty,
    );
  });

  test(
    'editing an ignore source mid-turn is recorded as policy_changed',
    () async {
      write('.gitignore', '*.log\n');
      write('web/.gitignore', 'dist/\n');
      write('a.txt', 'a');
      for (final edit in [
        () => write('web/.gitignore', 'dist/\n*.tmp\n'),
        () => write('.gitignore', '*.log\n!keep.log\n'),
        () => File(
          p.join(root.path, '.git', 'info', 'exclude'),
        ).writeAsStringSync('extra/\n'),
        () => write('deep/new/.gitignore', '*.bak\n'),
      ]) {
        final id = await begin();
        edit();
        final close = await service().close(id);
        expect(close.exitCode, 0, reason: close.encode());
        final warning = records(
          id,
        ).issues.singleWhere((issue) => issue.code == 'policy_changed');
        expect(warning.fatal, isFalse);
      }
    },
  );

  test(
    'a tool writing .gitignore into an ignored directory is not a policy change',
    () async {
      write('.gitignore', '.pytest_cache/\n.venv/\n');
      write('test_app.py', 'def test(): pass');
      final id = await begin();
      // pytest and python -m venv drop a "*" .gitignore into their own
      // directories. Git never reads them, because the directories are ignored.
      write('.pytest_cache/.gitignore', '*\n');
      write('.pytest_cache/v/cache/lastfailed', '{}');
      write('.venv/.gitignore', '*\n');
      write('test_app.py', 'def test(): assert True');
      final close = await service().close(id);
      expect(close.exitCode, 0, reason: close.encode());
      expect(
        records(id).issues.map((issue) => issue.code),
        isNot(contains('policy_changed')),
      );
      expect(
        records(id).files
            .where((file) => file.changeKind == CheckpointChangeKind.modified)
            .map((file) => file.filePath),
        ['test_app.py'],
      );

      // A .gitignore that Git does read (its directory is not ignored) is one.
      final next = await begin();
      write('cache/.gitignore', '*\n');
      final changed = await service().close(next);
      expect(changed.exitCode, 0, reason: changed.encode());
      expect(
        records(next).issues.map((issue) => issue.code),
        contains('policy_changed'),
      );
    },
  );

  test('a Git work tree without git fails with git_unavailable', () async {
    write('a.txt', 'a');
    final noGit = service(gitLocator: () => null);
    final began = await noGit.begin(source: 'test');
    expect(began.exitCode, 3);
    final id = (began.data['checkpoint'] as Map)['id'] as String;
    final issue = records(id).issues.single;
    expect(issue.code, 'git_unavailable');
    expect(issue.message, contains('git was not found'));
    expect(issue.fatal, isTrue);

    // A checkpoint begun with Git stays open when Git disappears at close.
    final open = await begin();
    final closed = await noGit.close(open);
    expect(closed.errors.single.code, 'git_unavailable');
    final view = await service().show(open);
    expect((view.data['checkpoint'] as Map)['status'], 'open');

    final restore = await CheckpointRestoreService(
      basePath: root.path,
      gitLocator: () => null,
    ).restore(open);
    expect(restore.errors.single.code, 'git_unavailable');

    final status = await describeIgnorePolicy(
      root.path,
      gitLocator: () => null,
    );
    expect(status.ok, isFalse);
    expect(status.text, startsWith('unavailable (git_unavailable)'));
  });

  test(
    'restore and redo never create, overwrite or delete a Git-ignored file',
    () async {
      write('modified.txt', 'before');
      write('deleted.txt', 'before');
      final id = await begin();
      write('modified.txt', 'after');
      File(p.join(root.path, 'deleted.txt')).deleteSync();
      write('created.txt', 'after');
      final close = await service().close(id);
      expect(close.exitCode, 0, reason: close.encode());

      final restorer = CheckpointRestoreService(basePath: root.path);
      // After the turn, the user ignores every path the checkpoint touched.
      write('.gitignore', 'modified.txt\ndeleted.txt\ncreated.txt\n');
      final preview = await restorer.restore(id);
      expect(preview.exitCode, 4, reason: preview.encode());
      final conflicts = (preview.data['conflicts'] as List).cast<Map>();
      expect(
        {for (final conflict in conflicts) conflict['path']: conflict['code']},
        {
          'modified.txt': 'git_ignored',
          'deleted.txt': 'git_ignored',
          'created.txt': 'git_ignored',
        },
      );
      final refused = await restorer.restore(id, apply: true);
      expect(refused.exitCode, 4);
      // Nothing was overwritten, created or deleted.
      expect(
        File(p.join(root.path, 'modified.txt')).readAsStringSync(),
        'after',
      );
      expect(File(p.join(root.path, 'deleted.txt')).existsSync(), isFalse);
      expect(
        File(p.join(root.path, 'created.txt')).readAsStringSync(),
        'after',
      );

      // Redo is checked the same way.
      File(p.join(root.path, '.gitignore')).deleteSync();
      final restored = await restorer.restore(id, apply: true);
      expect(restored.exitCode, 0, reason: restored.encode());
      write('.gitignore', 'modified.txt\n');
      final redo = await restorer.redo(id, apply: true);
      expect(redo.exitCode, 4, reason: redo.encode());
      expect(
        ((redo.data['conflicts'] as List).single as Map)['code'],
        'git_ignored',
      );
      expect(
        File(p.join(root.path, 'modified.txt')).readAsStringSync(),
        'before',
      );
    },
  );

  test('the watcher skips Git-ignored events in one batch', () async {
    write('.gitignore', '*.log\n');
    write('kept.txt', 'v1');
    final paths = DmcPaths(basePath: root.path);
    final database = DmcDatabase(paths.dbPath)..initialize();
    final policy = await loadIgnorePolicy(root.path, announce: false);
    expect(policy.gitMode, isTrue);
    final watcher = DmcWatcher(
      targetPath: root.path,
      database: database,
      snapshotsPath: paths.snapshotsPath,
      ignoreRules: policy.rules,
      git: policy.git,
      maxFileSizeBytes: 2048 * 1024,
      reconciliationInterval: const Duration(milliseconds: 100),
    );
    try {
      expect(await watcher.start(), isTrue);
      write('debug.log', 'ignored');
      write('kept.txt', 'v2');
      String? saved(String name) {
        final row = database.getLatestSnapshot(name);
        if (row == null) return null;
        return String.fromCharCodes(
          SnapshotStore.readVerifiedBytes(
            paths.snapshotsPath,
            row.snapshotPath,
            row.hash,
          ),
        );
      }

      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (saved('kept.txt') != 'v2') {
        if (DateTime.now().isAfter(deadline)) fail('kept.txt was not captured');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(database.getLatestSnapshot('debug.log'), isNull);
    } finally {
      await watcher.stop();
      database.close();
    }
  });

  test(
    'outside Git the subset parser and its refusals are unchanged',
    () async {
      final plain = Directory(p.join(sandbox.path, 'plain'))..createSync();
      await initDmc(basePath: plain.path);
      File(p.join(plain.path, 'web', '.gitignore'))
        ..createSync(recursive: true)
        ..writeAsStringSync('dist/\n');
      final policy = await loadIgnorePolicy(plain.path, announce: false);
      expect(policy.gitMode, isFalse);
      final result = await CheckpointService(
        basePath: plain.path,
        homePath: home.path,
      ).begin(source: 'test');
      expect(result.exitCode, 3);
      final id = (result.data['checkpoint'] as Map)['id'] as String;
      final database = DmcDatabase(DmcPaths(basePath: plain.path).dbPath)
        ..initialize();
      try {
        expect(
          CheckpointRepository(
            database,
          ).getIssues(id).map((issue) => issue.code),
          contains('nested_ignore'),
        );
      } finally {
        database.close();
      }
      File(p.join(plain.path, '.gitignore')).writeAsStringSync('!keep\n');
      expect(
        () => loadIgnorePolicy(plain.path, announce: false),
        throwsFormatException,
      );
    },
  );
}
