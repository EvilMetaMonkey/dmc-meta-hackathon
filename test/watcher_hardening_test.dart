import 'dart:async';
import 'dart:io';
import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<void> eventually(bool Function() check) async {
  final end = DateTime.now().add(const Duration(seconds: 8));
  while (!check() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(check(), isTrue);
}

class PausedStore extends SnapshotStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool paused = false;
  PausedStore({required super.database, required super.snapshotsPath});
  @override
  Future<List<int>> readSourceBytes(File source) async {
    if (!paused) {
      paused = true;
      entered.complete();
      await release.future;
    }
    return super.readSourceBytes(source);
  }
}

class AlwaysChangingStore extends SnapshotStore {
  int reads = 0;
  AlwaysChangingStore({required super.database, required super.snapshotsPath});
  @override
  Future<List<int>> readSourceBytes(File source) async {
    final bytes = await super.readSourceBytes(source);
    source.writeAsStringSync('changing ${reads++}' * (reads + 1));
    return bytes;
  }
}

/// Delete [file], retrying briefly: on Windows the watcher may still have
/// it open for a capture (errno 32, "used by another process").
Future<void> deleteWithRetry(File file) async {
  for (var attempt = 1; ; attempt++) {
    try {
      file.deleteSync();
      return;
    } on FileSystemException {
      if (attempt >= 20) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }
}

void main() {
  late Directory root;
  late DmcPaths paths;
  late DmcDatabase db;
  final watchers = <DmcWatcher>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('dmc_phase2_');
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    db = DmcDatabase(paths.dbPath)..initialize();
  });
  tearDown(() async {
    for (final watcher in watchers) {
      await watcher.stop();
    }
    watchers.clear();
    db.close();
    await root.delete(recursive: true);
  });
  Future<DmcWatcher> makeWatcher({
    SnapshotStore? store,
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    final watcher = DmcWatcher(
      targetPath: root.path,
      database: db,
      snapshotsPath: paths.snapshotsPath,
      ignoreRules: await loadIgnoreRules(root.path),
      maxFileSizeBytes: 2048 * 1024,
      reconciliationInterval: interval,
      snapshotStore: store,
    );
    watchers.add(watcher);
    return watcher;
  }

  String? saved(String name) {
    final row = db.getLatestSnapshot(name);
    if (row == null || row.hash == tombstoneHash) return null;
    return String.fromCharCodes(
      SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        row.snapshotPath,
        row.hash,
      ),
    );
  }

  test(
    'init excludes vault contents from Git and preserves existing rules',
    () async {
      final ignore = File(p.join(paths.dmcPath, '.gitignore'));
      expect(ignore.readAsStringSync(), '*\n');
      final initialized = await Process.run('git', [
        'init',
      ], workingDirectory: root.path);
      expect(initialized.exitCode, 0, reason: '${initialized.stderr}');
      final ignored = await Process.run('git', [
        'check-ignore',
        '.dmc/dmc.db',
      ], workingDirectory: root.path);
      expect(ignored.exitCode, 0, reason: '${ignored.stderr}');
      expect('${ignored.stdout}'.trim(), '.dmc/dmc.db');
      ignore.writeAsStringSync('*\n# Keep this local note\n');
      await initDmc(basePath: root.path);
      expect(ignore.readAsStringSync(), '*\n# Keep this local note\n');
    },
  );

  test('ready includes a baseline and the first edit can be undone', () async {
    final file = File(p.join(root.path, 'first.txt'))
      ..writeAsStringSync('original');
    final watcher = await makeWatcher();
    expect(await watcher.start(), isTrue);
    expect(saved('first.txt'), 'original');
    file.writeAsStringSync('first edit');
    await eventually(() => saved('first.txt') == 'first edit');
    await watcher.stop();
    expect(
      (await undoFile('first.txt', basePath: root.path)).hadError,
      isFalse,
    );
    expect(file.readAsStringSync(), 'original');
  });

  test(
    'real create, rename, directory move and atomic replacement are captured',
    () async {
      final watcher = await makeWatcher();
      expect(await watcher.start(), isTrue);
      final file = File(p.join(root.path, 'created.txt'))
        ..writeAsStringSync('new');
      await eventually(() => saved('created.txt') == 'new');
      final moved = file.renameSync(p.join(root.path, 'renamed.txt'));
      await eventually(
        () =>
            saved('renamed.txt') == 'new' &&
            db.getLatestSnapshot('created.txt')?.hash == tombstoneHash,
      );
      final replacement = File(p.join(root.path, 'temp-save'))
        ..writeAsStringSync('atomic');
      replacement.renameSync(moved.path);
      await eventually(() => saved('renamed.txt') == 'atomic');
      final dir = Directory(p.join(root.path, 'nested'))..createSync();
      File(p.join(dir.path, 'child.txt')).writeAsStringSync('child');
      await eventually(() => saved(p.join('nested', 'child.txt')) == 'child');
      dir.renameSync(p.join(root.path, 'moved-dir'));
      await eventually(
        () =>
            saved(p.join('moved-dir', 'child.txt')) == 'child' &&
            db.getLatestSnapshot(p.join('nested', 'child.txt'))?.hash ==
                tombstoneHash,
      );
      await deleteWithRetry(moved);
      await eventually(
        () => db.getLatestSnapshot('renamed.txt')?.hash == tombstoneHash,
      );
    },
  );

  test(
    'native events capture modification without polling reconciliation',
    () async {
      final file = File(p.join(root.path, 'event.txt'))
        ..writeAsStringSync('before');
      final watcher = await makeWatcher(interval: const Duration(hours: 1));
      expect(await watcher.start(), isTrue);
      file.writeAsStringSync('event change');
      await eventually(() => saved('event.txt') == 'event change');
    },
  );

  test(
    'immediate shutdown captures the last write inside debounce window',
    () async {
      final file = File(p.join(root.path, 'last.txt'))
        ..writeAsStringSync('before');
      final watcher = await makeWatcher();
      await watcher.start();
      file.writeAsStringSync('last change');
      await watcher.stop();
      expect(saved('last.txt'), 'last change');
      expect(
        readControlJson(paths, 'watcher-health.json')!['phase'],
        'stopped',
      );
    },
  );

  test(
    'startup queues changes and shutdown waits for in-flight baseline reads',
    () async {
      final file = File(p.join(root.path, 'queued.txt'))
        ..writeAsStringSync('initial');
      final paused = PausedStore(
        database: db,
        snapshotsPath: paths.snapshotsPath,
      );
      final watcher = await makeWatcher(store: paused);
      final starting = watcher.start();
      await paused.entered.future;
      expect(watcher.isReady, isFalse);
      file.writeAsStringSync('changed during startup');
      var stopped = false;
      final stopping = watcher.stop().then((_) => stopped = true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(stopped, isFalse);
      paused.release.complete();
      await starting;
      await stopping;
      expect(saved('queued.txt'), 'changed during startup');
    },
  );

  test('restart reconciles changes and deletions made while stopped', () async {
    final first = File(p.join(root.path, 'offline.txt'))
      ..writeAsStringSync('before');
    final removed = File(p.join(root.path, 'deleted.txt'))
      ..writeAsStringSync('exists');
    final watcher = await makeWatcher();
    await watcher.start();
    await watcher.stop();
    first.writeAsStringSync('offline edit');
    removed.deleteSync();
    final restarted = await makeWatcher();
    expect(await restarted.start(), isTrue);
    expect(saved('offline.txt'), 'offline edit');
    expect(db.getLatestSnapshot('deleted.txt')!.hash, tombstoneHash);
  });

  test(
    'unchanged events and reconciliation do not duplicate history',
    () async {
      final file = File(p.join(root.path, 'same.txt'))
        ..writeAsStringSync('same');
      final watcher = await makeWatcher();
      await watcher.start();
      final count = db.getHistoryCount();
      for (var i = 0; i < 3; i++) {
        file.writeAsStringSync('same');
        await watcher.captureFileNow(file.path);
      }
      await watcher.stop();
      expect(db.getHistoryCount(), count);
    },
  );

  test(
    'unstable source fails with bounded retries and persists unhealthy state',
    () async {
      File(p.join(root.path, 'unstable.txt')).writeAsStringSync('original');
      final store = AlwaysChangingStore(
        database: db,
        snapshotsPath: paths.snapshotsPath,
      );
      final watcher = await makeWatcher(
        store: store,
        interval: const Duration(hours: 1),
      );
      expect(await watcher.start(), isFalse);
      expect(store.reads, lessThanOrEqualTo(18));
      expect(db.getHistoryCount(), 0);
      await watcher.stop();
      final health = readControlJson(paths, 'watcher-health.json')!;
      expect(health['phase'], 'failed');
      expect((health['errors'] as Map), isNotEmpty);
      expect(await runDoctor(basePath: root.path, homePath: root.path), isTrue);
    },
  );

  test(
    'scan prunes ignored directories and reports nested ignore uncertainty',
    () async {
      final ignored = Directory(p.join(root.path, 'node_modules'))
        ..createSync();
      File(p.join(ignored.path, 'never.txt')).writeAsStringSync('ignored');
      final folder = Directory(p.join(root.path, 'src'))..createSync();
      File(p.join(folder.path, '.gitignore')).writeAsStringSync('private.txt');
      final scan = await scanWorkspace(paths, await loadIgnoreRules(root.path));
      expect(scan.directories, isNot(contains(ignored.path)));
      expect(scan.errors.keys, contains(p.join('src', '.gitignore')));
      expect(
        await takeManualSnapshot(basePath: root.path, homePath: root.path),
        1,
      );
      expect(db.getHistoryCount(), 0);
    },
  );

  test(
    'symlink files and parent directories are excluded from capture and restore',
    () async {
      final outside = Directory.systemTemp.createTempSync('dmc_outside_');
      try {
        final target = File(p.join(outside.path, 'secret.txt'))
          ..writeAsStringSync('keep');
        final inside = File(p.join(root.path, 'inside.txt'))
          ..writeAsStringSync('inside');
        try {
          Link(p.join(root.path, 'external.txt')).createSync(target.path);
          Link(p.join(root.path, 'internal-link.txt')).createSync(inside.path);
          Link(p.join(root.path, 'parent-link')).createSync(outside.path);
        } on FileSystemException {
          if (!Platform.isWindows) rethrow;
          markTestSkipped(
            'File symlink creation requires Windows developer mode/privilege.',
          );
          return;
        }
        final scan = await scanWorkspace(
          paths,
          await loadIgnoreRules(root.path),
        );
        expect(
          scan.exclusions.values.where((reason) => reason == 'symlink'),
          hasLength(3),
        );
        expect(scan.files, contains(inside.path));
        for (final name in [
          'external.txt',
          'internal-link.txt',
          p.join('parent-link', 'secret.txt'),
        ]) {
          expect(() => paths.resolveFile(name), throwsArgumentError);
          expect(
            (await restoreFile(name, basePath: root.path)).hadError,
            isTrue,
          );
        }
        final watcher = await makeWatcher();
        expect(
          (await watcher.captureFileNow(
            p.join(root.path, 'external.txt'),
          )).status,
          CaptureStatus.skipped,
        );
        expect(target.readAsStringSync(), 'keep');
      } finally {
        outside.deleteSync(recursive: true);
      }
    },
  );

  test('vault metadata and root itself cannot be restore targets', () {
    for (final name in [
      '.',
      '.dmc/config.json',
      '.git/config',
      '../escape.txt',
    ]) {
      expect(() => paths.resolveFile(name), throwsArgumentError);
    }
  });

  test(
    'ignore anchoring, recursive glob and directory-only semantics are explicit',
    () {
      expect(
        IgnoreRule.fromPattern('/secret.txt')!.matches('secret.txt'),
        isTrue,
      );
      expect(
        IgnoreRule.fromPattern('/secret.txt')!.matches('sub/secret.txt'),
        isFalse,
      );
      expect(
        IgnoreRule.fromPattern('**/secret.txt')!.matches('sub/deep/secret.txt'),
        isTrue,
      );
      expect(IgnoreRule.fromPattern('build/')!.matches('build'), isFalse);
      expect(
        IgnoreRule.fromPattern('build/')!.matches('build', isDirectory: true),
        isTrue,
      );
      expect(
        IgnoreRule.fromPattern('build/')!.matches('build/output.txt'),
        isTrue,
      );
      expect(
        () => IgnoreRule.fromPattern('!secret.txt'),
        throwsFormatException,
      );
      expect(() => IgnoreRule.fromPattern('[ab].txt'), throwsFormatException);
    },
  );

  test(
    'authenticated stop drains the runner and stale PIDs are never killed',
    () async {
      File(p.join(root.path, 'runner.txt')).writeAsStringSync('before');
      final run = watchDmc(basePath: root.path);
      addTearDown(() async {
        await stopDaemon(basePath: root.path);
        await run;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while ((await queryWatcher(paths))?['ready'] != true &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect((await queryWatcher(paths))?['ready'], isTrue);
      await expectLater(
        WatcherControl.acquire(paths, state: () => {}),
        throwsStateError,
      );
      File(p.join(root.path, 'runner.txt')).writeAsStringSync('last');
      expect(await stopDaemon(basePath: root.path), 0);
      expect(await run, 0);
      expect(saved('runner.txt'), 'last');
      expect(await queryWatcher(paths), isNull);
    },
  );

  test('forged control token cannot request a stop', () async {
    final control = await WatcherControl.acquire(
      paths,
      state: () => {'ready': true},
    );
    try {
      final original = readControlJson(paths, 'watcher-control.json')!;
      writeControlJson(paths, 'watcher-control.json', {
        ...original,
        'token': '0' * 64,
      });
      expect(await queryWatcher(paths, stop: true), isNull);
      expect(control.stopRequested.isCompleted, isFalse);
      writeControlJson(paths, 'watcher-control.json', original);
    } finally {
      await control.close();
    }
  });

  test(
    'legacy PID metadata blocks starting a second generation watcher',
    () async {
      await writeDaemonPid(424242, basePath: root.path);
      await expectLater(
        WatcherControl.acquire(paths, state: () => {}),
        throwsStateError,
      );
      expect(await readDaemonPid(basePath: root.path), 424242);
    },
  );

  test(
    'legacy commands report failure outside an initialized workspace',
    () async {
      final empty = Directory.systemTemp.createTempSync('dmc_uninitialized_');
      final original = Directory.current;
      try {
        Directory.current = empty;
        for (final args in [
          ['log'],
          ['marks'],
          ['mark', 'test'],
          ['task', 'start', 'test'],
          ['task', 'end'],
          ['status'],
        ]) {
          expect(await runCli(args), 1, reason: args.join(' '));
        }
        expect(await runCli(['log', 'extra']), 2);
        expect(await runCli(['restore', 'a', 'b']), 2);
      } finally {
        Directory.current = original;
        empty.deleteSync(recursive: true);
      }
    },
  );

  test(
    'CLI help succeeds and unknown arguments fail without escaping exceptions',
    () async {
      expect(await runCli(['--help']), 0);
      expect(await runCli(['restore', '--help']), 0);
      expect(await runCli(['task', 'start', '--help']), 0);
      expect(await runCli(['--not-an-option']), 2);
    },
  );
}
