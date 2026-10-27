import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class FailingCheckpointStore extends SnapshotStore {
  final String failedPath;

  FailingCheckpointStore({
    required super.database,
    required super.snapshotsPath,
    required this.failedPath,
  });

  @override
  Future<CaptureResult> captureFile({
    required File source,
    required String relativePath,
    required int timestamp,
    int? burstId,
    String? taskName,
    int? maxFileSizeBytes,
    bool Function(List<int> bytes)? skipContent,
    bool recordInitialAbsence = false,
    bool requireStableRead = false,
  }) {
    if (relativePath == failedPath) {
      return Future.value(
        const CaptureResult(
          CaptureStatus.failed,
          message: 'injected read failure',
        ),
      );
    }
    return super.captureFile(
      source: source,
      relativePath: relativePath,
      timestamp: timestamp,
      burstId: burstId,
      taskName: taskName,
      maxFileSizeBytes: maxFileSizeBytes,
      skipContent: skipContent,
      recordInitialAbsence: recordInitialAbsence,
      requireStableRead: requireStableRead,
    );
  }
}

class PausingCheckpointStore extends SnapshotStore {
  final entered = Completer<void>();
  final release = Completer<void>();
  var paused = false;

  PausingCheckpointStore({
    required super.database,
    required super.snapshotsPath,
  });

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

Future<List<String>> checkpointPrints(Future<void> Function() action) async {
  final output = <String>[];
  await runZoned(
    action,
    zoneSpecification: ZoneSpecification(
      print: (_, _, _, message) => output.add(message),
    ),
  );
  return output;
}

Future<T> inCheckpointDirectory<T>(
  String path,
  Future<T> Function() action,
) async {
  final previous = Directory.current.path;
  Directory.current = path;
  try {
    return await action();
  } finally {
    Directory.current = previous;
  }
}

void main() {
  late Directory root;
  late DmcPaths paths;
  late CheckpointService service;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('dmc_checkpoint_');
    paths = DmcPaths(basePath: root.path);
    await initDmc(basePath: root.path);
    service = CheckpointService(basePath: root.path, homePath: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'begin and close record modify, create, delete and rename manifests',
    () async {
      File(p.join(root.path, '.dmcignore')).writeAsStringSync('ignored/\n');
      File(p.join(root.path, 'modified.txt')).writeAsStringSync('before');
      final deleted = File(p.join(root.path, 'deleted.txt'))
        ..writeAsStringSync('delete me');
      final renamed = File(p.join(root.path, 'old-name.txt'))
        ..writeAsStringSync('rename me');
      Directory(p.join(root.path, 'ignored')).createSync();
      File(
        p.join(root.path, 'ignored', 'secret.txt'),
      ).writeAsStringSync('secret');
      File(p.join(root.path, 'binary.dat')).writeAsBytesSync([1, 0, 2]);
      File(
        paths.configPath,
      ).writeAsStringSync(jsonEncode({'max_file_size_kb': 1}));
      File(p.join(root.path, 'large.txt')).writeAsStringSync('x' * 2048);
      final link = Link(p.join(root.path, 'linked.txt'));
      var linkCreated = true;
      try {
        link.createSync(p.join(root.path, 'modified.txt'));
      } on FileSystemException {
        linkCreated = false;
      }

      final begin = await service.begin(label: 'agent run', source: 'haven');
      expect(begin.exitCode, 0, reason: begin.encode());
      final id = (begin.data['checkpoint'] as Map)['id'] as String;
      final openDb = DmcDatabase(paths.dbPath)..initialize();
      var view = CheckpointRepository(openDb).getView(id)!;
      expect(view.checkpoint.status, CheckpointStatus.open);
      expect(view.files.map((file) => file.filePath), contains('modified.txt'));
      expect(
        view.issues.map((issue) => issue.code),
        containsAll([
          'ignored_path',
          'binary_file',
          'oversized_file',
          if (linkCreated) 'symlink',
        ]),
      );
      openDb.close();

      File(p.join(root.path, 'modified.txt')).writeAsStringSync('after');
      deleted.deleteSync();
      renamed.renameSync(p.join(root.path, 'new-name.txt'));
      File(p.join(root.path, 'created.txt')).writeAsStringSync('created');

      // A new service instance proves close does not depend on process memory.
      final close = await CheckpointService(
        basePath: root.path,
        homePath: root.path,
      ).close(id);
      expect(close.exitCode, 0, reason: close.encode());
      final closedDb = DmcDatabase(paths.dbPath)..initialize();
      view = CheckpointRepository(closedDb).getView(id)!;
      closedDb.close();
      expect(view.checkpoint.status, CheckpointStatus.closed);
      final changes = {
        for (final file in view.files) file.filePath: file.changeKind,
      };
      expect(changes['modified.txt'], CheckpointChangeKind.modified);
      expect(changes['deleted.txt'], CheckpointChangeKind.deleted);
      expect(changes['old-name.txt'], CheckpointChangeKind.deleted);
      expect(changes['new-name.txt'], CheckpointChangeKind.created);
      expect(changes['created.txt'], CheckpointChangeKind.created);

      final diff = await service.diff(id);
      expect(diff.exitCode, 0);
      final diffFiles = diff.data['files'] as List;
      expect(
        diffFiles
            .where((file) => (file as Map)['change'] != 'unchanged')
            .length,
        greaterThanOrEqualTo(5),
      );
    },
  );

  test('capture failure makes begin invalid and permits inspection', () async {
    File(p.join(root.path, 'good.txt')).writeAsStringSync('good');
    File(p.join(root.path, 'bad.txt')).writeAsStringSync('bad');
    final failing = CheckpointService(
      basePath: root.path,
      homePath: root.path,
      storeFactory: (database, snapshotsPath) => FailingCheckpointStore(
        database: database,
        snapshotsPath: snapshotsPath,
        failedPath: 'bad.txt',
      ),
    );
    final begin = await failing.begin();
    expect(begin.exitCode, 3);
    final checkpoint = begin.data['checkpoint'] as Map;
    expect(checkpoint['status'], 'invalid');
    expect(
      begin.errors.any(
        (error) => error.code == 'capture_failed' && error.path == 'bad.txt',
      ),
      isTrue,
    );
    final show = await service.show(checkpoint['id'] as String);
    expect(show.exitCode, 0);
    expect((show.data['files'] as List), isNotEmpty);
  });

  test('invalid policy produces an inspectable invalid checkpoint', () async {
    File(p.join(root.path, '.dmcignore')).writeAsStringSync('!unsupported\n');
    final result = await service.begin();
    expect(result.exitCode, 3);
    expect((result.data['checkpoint'] as Map)['status'], 'invalid');
    expect(result.errors.single.code, 'policy_invalid');
  });

  test(
    'one active checkpoint is enforced and policy drift is recorded at close',
    () async {
      File(p.join(root.path, 'notes.txt')).writeAsStringSync('before');
      final first = await service.begin();
      expect(first.exitCode, 0);
      final id = (first.data['checkpoint'] as Map)['id'] as String;
      final second = await service.begin();
      expect(second.exitCode, 3);
      expect(second.errors.single.code, 'checkpoint_already_active');
      File(p.join(root.path, '.dmcignore')).writeAsStringSync('generated/\n');
      final close = await service.close(id);
      expect(close.exitCode, 0, reason: close.encode());
      final closed = close.data['checkpoint'] as Map;
      expect(closed['status'], 'closed');
      expect(
        closed['closePolicyFingerprint'],
        isNot(closed['policyFingerprint']),
      );
      expect(
        close.warnings.any((warning) => warning.code == 'policy_changed'),
        isTrue,
      );
    },
  );

  test('checkpoint lifecycle commands are serialized across callers', () async {
    File(p.join(root.path, 'slow.txt')).writeAsStringSync('before');
    final created = Completer<PausingCheckpointStore>();
    final slowService = CheckpointService(
      basePath: root.path,
      homePath: root.path,
      storeFactory: (database, snapshotsPath) {
        final store = PausingCheckpointStore(
          database: database,
          snapshotsPath: snapshotsPath,
        );
        created.complete(store);
        return store;
      },
    );
    final running = slowService.begin();
    final store = await created.future;
    await store.entered.future;
    final competing = await service.begin();
    expect(competing.exitCode, 3);
    expect(competing.errors.single.code, 'checkpoint_busy');
    store.release.complete();
    expect((await running).exitCode, 0);
  });

  test(
    'release can explicitly abandon an interrupted checkpoint state',
    () async {
      final database = DmcDatabase(paths.dbPath)..initialize();
      final repository = CheckpointRepository(database);
      repository.createCheckpoint(
        id: 'cp_interrupted',
        label: null,
        source: 'manual',
        createdAt: 1,
        policyFingerprint: 'policy',
      );
      database.close();
      final released = await service.release('cp_interrupted');
      expect(released.exitCode, 0);
      expect((released.data['checkpoint'] as Map)['status'], 'released');
      expect((await service.begin()).exitCode, 0);
    },
  );

  test(
    'close resumes a persisted closing checkpoint from durable before-state',
    () async {
      File(p.join(root.path, 'resume.txt')).writeAsStringSync('before');
      final begin = await service.begin();
      final id = (begin.data['checkpoint'] as Map)['id'] as String;
      File(p.join(root.path, 'resume.txt')).writeAsStringSync('after');
      final database = DmcDatabase(paths.dbPath)..initialize();
      database.db.execute(
        "UPDATE checkpoints SET status = 'closing' WHERE id = ?",
        [id],
      );
      database.close();
      final close = await CheckpointService(
        basePath: root.path,
        homePath: root.path,
      ).close(id);
      expect(close.exitCode, 0, reason: close.encode());
      final closedDb = DmcDatabase(paths.dbPath)..initialize();
      final file = CheckpointRepository(
        closedDb,
      ).getFiles(id).singleWhere((file) => file.filePath == 'resume.txt');
      expect(file.changeKind, CheckpointChangeKind.modified);
      closedDb.close();
    },
  );

  test('checkpoint references pin history until explicit release', () async {
    File(p.join(root.path, 'pin.txt')).writeAsStringSync('pinned');
    final begin = await service.begin();
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    final database = DmcDatabase(paths.dbPath)..initialize();
    final repository = CheckpointRepository(database);
    final snapshotId = repository
        .getFiles(id)
        .singleWhere((file) => file.filePath == 'pin.txt')
        .beforeSnapshotId!;
    database.db.execute('UPDATE history SET timestamp = 0');
    expect(
      database
          .getExpiredSnapshotRecords(const Duration(hours: 1))
          .map((row) => row.id),
      isNot(contains(snapshotId)),
    );
    database.close();
    expect((await service.close(id)).exitCode, 0);
    expect((await service.release(id)).exitCode, 0);
    final releasedDb = DmcDatabase(paths.dbPath)..initialize();
    expect(
      releasedDb
          .getExpiredSnapshotRecords(const Duration(hours: 1))
          .map((row) => row.id),
      contains(snapshotId),
    );
    final released = CheckpointRepository(releasedDb).getView(id)!;
    expect(released.checkpoint.status, CheckpointStatus.released);
    expect(
      released.files
          .singleWhere((file) => file.filePath == 'pin.txt')
          .beforeSnapshotId,
      isNull,
    );
    expect(
      released.files
          .singleWhere((file) => file.filePath == 'pin.txt')
          .beforeHash,
      isNotNull,
    );
    releasedDb.close();
  });

  test(
    'JSON commands emit one deterministic schema version 1 envelope',
    () async {
      File(p.join(root.path, 'notes.txt')).writeAsStringSync('before');
      late int beginCode;
      final beginOutput = await inCheckpointDirectory(
        root.path,
        () => checkpointPrints(() async {
          beginCode = await runCli([
            'checkpoint',
            'begin',
            '--label',
            'CLI run',
            '--source',
            'haven',
            '--json',
          ]);
        }),
      );
      expect(beginCode, 0);
      expect(beginOutput, hasLength(1));
      final beginJson = jsonDecode(beginOutput.single) as Map<String, dynamic>;
      expect(beginJson.keys.toList(), [
        'schemaVersion',
        'dmcVersion',
        'ok',
        'exitCode',
        'command',
        'workspace',
        'data',
        'warnings',
        'errors',
      ]);
      expect(beginJson['schemaVersion'], 1);
      expect(beginJson['dmcVersion'], '1.1.0-dev.5.1');
      expect(beginJson['exitCode'], 0);
      expect(beginJson['workspace']['path'], root.resolveSymbolicLinksSync());
      expect(beginJson['workspace']['fingerprint'], startsWith('sha256:'));
      expect(beginJson['command'], 'checkpoint.begin');
      expect(beginJson['ok'], isTrue);
      expect(beginJson.toString(), isNot(contains('before')));
      final id = (beginJson['data']['checkpoint'] as Map)['id'] as String;

      File(p.join(root.path, 'notes.txt')).writeAsStringSync('after');
      late int closeCode;
      final closeOutput = await inCheckpointDirectory(
        root.path,
        () => checkpointPrints(() async {
          closeCode = await runCli(['checkpoint', 'close', id, '--json']);
        }),
      );
      expect(closeCode, 0);
      expect(closeOutput, hasLength(1));
      final closeJson = jsonDecode(closeOutput.single) as Map<String, dynamic>;
      expect(closeJson['command'], 'checkpoint.close');
      expect(closeJson['schemaVersion'], 1);

      late int badCode;
      final badOutput = await checkpointPrints(() async {
        badCode = await runCli(['checkpoint', 'show', '--json']);
      });
      expect(badCode, 2);
      expect(badOutput, hasLength(1));
      expect((jsonDecode(badOutput.single) as Map)['ok'], isFalse);
    },
  );

  test('capabilities declares checkpoint apply and recovery support', () async {
    late int code;
    final output = await checkpointPrints(() async {
      code = await runCli(['capabilities', '--json']);
    });
    expect(code, 0);
    expect(output, hasLength(1));
    final decoded = jsonDecode(output.single) as Map<String, dynamic>;
    expect(decoded['schemaVersion'], 1);
    expect(decoded['data']['checkpointApply'], isTrue);
    expect(decoded['data']['contract'], 'haven-checkpoint-v1');
    expect(decoded['data']['features']['fileContentsInJson'], isFalse);
    expect(decoded['data']['commands'], contains('checkpoint.begin'));
    expect(decoded['data']['commands'], contains('checkpoint.list'));
    expect(decoded['data']['commands'], contains('checkpoint.restore'));
    expect(decoded['data']['commands'], contains('checkpoint.recover'));
  });

  test('checkpoint list and schema negotiation are machine-readable', () async {
    File(p.join(root.path, 'list.txt')).writeAsStringSync('before');
    final begin = await service.begin(label: 'listed run', source: 'test');
    final id = (begin.data['checkpoint'] as Map)['id'] as String;

    late int listCode;
    final listOutput = await inCheckpointDirectory(
      root.path,
      () => checkpointPrints(() async {
        listCode = await runCli([
          'checkpoint',
          'list',
          '--limit',
          '10',
          '--json',
          '--schema-version',
          '1',
        ]);
      }),
    );
    expect(listCode, 0);
    final list = jsonDecode(listOutput.single) as Map<String, dynamic>;
    expect(list['data']['count'], 1);
    expect(list['data']['checkpoints'][0]['id'], id);

    late int badSchemaCode;
    final badSchemaOutput = await inCheckpointDirectory(
      root.path,
      () => checkpointPrints(() async {
        badSchemaCode = await runCli([
          'checkpoint',
          'list',
          '--json',
          '--schema-version',
          '999',
        ]);
      }),
    );
    expect(badSchemaCode, 2);
    final badSchema =
        jsonDecode(badSchemaOutput.single) as Map<String, dynamic>;
    expect(badSchema['exitCode'], 2);
    expect(badSchema['errors'][0]['code'], 'unsupported_schema_version');
  });

  test(
    'status and doctor surface active and interrupted checkpoints',
    () async {
      final database = DmcDatabase(paths.dbPath)..initialize();
      CheckpointRepository(database).createCheckpoint(
        id: 'cp_stuck',
        label: 'stuck begin',
        source: 'haven',
        createdAt: 1,
        policyFingerprint: 'policy',
      );
      database.close();
      final status = await checkpointPrints(() async {
        expect(await showStatus(basePath: root.path, homePath: root.path), 0);
      });
      expect(status.join('\n'), contains('cp_stuck (creating'));
      final doctor = await checkpointPrints(() async {
        expect(
          await runDoctor(basePath: root.path, homePath: root.path),
          isTrue,
        );
      });
      expect(doctor.join('\n'), contains('Interrupted checkpoint states: 1'));
      expect(doctor.join('\n'), contains('cp_stuck (creating)'));
    },
  );
}
