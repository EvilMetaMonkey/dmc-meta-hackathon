import 'dart:io';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'checkpoint_repository.dart';
import 'checkpoint_operation_repository.dart';
import 'checkpoint_operation_models.dart';
import 'database.dart';
import 'ignore.dart';
import 'snapshot_store.dart';
import 'workspace.dart';
import 'watcher_control.dart';

Future<bool> runDoctor({String? basePath, String? homePath}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDir = paths.dmcDirectory;
  if (!await dmcDir.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return true;
  }

  try {
    await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return true;
  }

  late final DmcDatabase db;
  if (!File(paths.dbPath).existsSync()) {
    print('[DMC] Error: Database file is missing: ${paths.dbPath}');
    return true;
  }
  try {
    db = DmcDatabase(paths.dbPath);
    db.initialize();
  } catch (e) {
    print('[DMC] Error opening database: $e');
    return true;
  }

  final snapshotRecords = db.getAllSnapshotRecords();
  final databaseCheck = db.db
      .select('PRAGMA integrity_check')
      .map((row) => row.values.first)
      .toList();
  final danglingReferences = db.db.select('''
    SELECT id FROM restore_events e WHERE
      NOT EXISTS (SELECT 1 FROM history h WHERE h.id = e.snapshot_id)
      OR (e.overwritten_snapshot_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM history h WHERE h.id = e.overwritten_snapshot_id))
    UNION ALL
    SELECT name FROM marks m WHERE NOT EXISTS
      (SELECT 1 FROM history h WHERE h.burst_id = m.burst_id)
    UNION ALL
    SELECT checkpoint_id || ':' || file_path FROM checkpoint_files cf WHERE
      (cf.before_snapshot_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM history h WHERE h.id = cf.before_snapshot_id))
      OR (cf.after_snapshot_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM history h WHERE h.id = cf.after_snapshot_id))
    UNION ALL
    SELECT operation_id || ':' || file_path
    FROM checkpoint_operation_files cof WHERE
      (cof.intended_snapshot_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM history h WHERE h.id = cof.intended_snapshot_id))
      OR (cof.pre_snapshot_id IS NOT NULL AND NOT EXISTS
        (SELECT 1 FROM history h WHERE h.id = cof.pre_snapshot_id))
  ''').length;
  final checkpointRepository = CheckpointRepository(db);
  final interruptedCheckpoints = db.db
      .select(
        "SELECT id, status FROM checkpoints WHERE status IN ('creating', 'closing') ORDER BY created_at",
      )
      .map((row) => '${row['id']} (${row['status']})')
      .toList();
  final invalidCheckpoints = db.db
      .select(
        "SELECT id FROM checkpoints WHERE status = 'invalid' ORDER BY created_at",
      )
      .map((row) => row['id'] as String)
      .toList();
  final activeCheckpoint = checkpointRepository.getActiveCheckpoint();
  final operationRepository = CheckpointOperationRepository(db);
  final incompleteOperations = operationRepository.incomplete();
  final knownOperations = db.db
      .select('SELECT id, status FROM checkpoint_operations')
      .map((row) => (id: row['id'] as String, status: row['status'] as String))
      .toList();
  db.close();

  final missingSnapshotFiles = <String>[];
  final corruptSnapshotFiles = <String>[];
  final referencedSnapshotPaths = <String>{};
  for (final record in snapshotRecords) {
    if (isTombstoneSnapshot(
      hash: record.hash,
      snapshotPath: record.snapshotPath,
    )) {
      continue;
    }

    referencedSnapshotPaths.add(record.snapshotPath);
    try {
      final snapshotFile = SnapshotStore.snapshotFile(
        paths.snapshotsPath,
        record.snapshotPath,
      );
      if (!snapshotFile.existsSync()) {
        missingSnapshotFiles.add(record.snapshotPath);
      } else {
        SnapshotStore.readVerifiedBytes(
          paths.snapshotsPath,
          record.snapshotPath,
          record.hash,
        );
      }
    } catch (e) {
      corruptSnapshotFiles.add('${record.snapshotPath}: $e');
    }
  }

  final snapshotsDir = Directory(paths.snapshotsPath);
  final orphanedSnapshotFiles = <String>[];
  if (await snapshotsDir.exists()) {
    await for (final entity in snapshotsDir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (!referencedSnapshotPaths.contains(name)) {
        orphanedSnapshotFiles.add(name);
      }
    }
  }
  final stagingFiles = <String>[];
  await for (final entity in dmcDir.list(followLinks: false)) {
    if (p.basename(entity.path).startsWith('.capture-')) {
      stagingFiles.add(p.basename(entity.path));
    }
  }
  final operationStorageIssues = <String>[];
  try {
    final operationsPath = paths.operationsPath;
    final operationsType = FileSystemEntity.typeSync(
      operationsPath,
      followLinks: false,
    );
    if (operationsType != FileSystemEntityType.notFound &&
        operationsType != FileSystemEntityType.directory) {
      operationStorageIssues.add('operations (not a directory)');
    } else if (operationsType == FileSystemEntityType.directory) {
      final operationsDirectory = Directory(operationsPath);
      final known = {
        for (final operation in knownOperations) operation.id: operation.status,
      };
      for (final entity in operationsDirectory.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type != FileSystemEntityType.directory) {
          operationStorageIssues.add('$name (not a directory)');
        } else if (!known.containsKey(name)) {
          operationStorageIssues.add('$name (no journal)');
        } else if (!{
          'planned',
          'applying',
          'failed',
          'rolling_back',
        }.contains(known[name])) {
          operationStorageIssues.add('$name (left over after ${known[name]})');
        }
      }
    }
  } catch (error) {
    operationStorageIssues.add(error.toString());
  }

  print('[DMC] Doctor');
  final live = await queryWatcher(paths);
  final health = live ?? readControlJson(paths, 'watcher-health.json');
  final watcherErrors = health?['errors'] as Map?;
  final interrupted =
      live == null &&
      health != null &&
      health['phase'] != 'stopped' &&
      health['phase'] != 'failed';
  if (health != null) {
    print(
      'Watcher state: ${health['phase']}${interrupted ? ' (not running; interrupted or stale)' : ''}',
    );
    print('Watcher errors: ${watcherErrors ?? {}}');
    print('Excluded paths: ${health['exclusions'] ?? {}}');
  }
  final ignorePolicy = await describeIgnorePolicy(paths.rootPath);
  print('Ignore policy: ${ignorePolicy.text}');
  print('DB access: ok');
  print('Database integrity: ${databaseCheck.join(', ')}');
  print('Missing snapshot files: ${missingSnapshotFiles.length}');
  print('Corrupt snapshot files: ${corruptSnapshotFiles.length}');
  print('Dangling database references: $danglingReferences');
  print(
    'Active checkpoint: ${activeCheckpoint == null ? 'none' : '${activeCheckpoint.id} (${activeCheckpoint.status.name})'}',
  );
  print('Interrupted checkpoint states: ${interruptedCheckpoints.length}');
  print('Invalid checkpoints: ${invalidCheckpoints.length}');
  print('Incomplete checkpoint operations: ${incompleteOperations.length}');
  print('Operation storage issues: ${operationStorageIssues.length}');
  print('Orphaned snapshot files: ${orphanedSnapshotFiles.length}');
  print('Staging entries (may be active captures): ${stagingFiles.length}');

  final hasIssues =
      interrupted ||
      !ignorePolicy.ok ||
      (watcherErrors?.isNotEmpty ?? false) ||
      missingSnapshotFiles.isNotEmpty ||
      orphanedSnapshotFiles.isNotEmpty ||
      corruptSnapshotFiles.isNotEmpty ||
      danglingReferences > 0 ||
      interruptedCheckpoints.isNotEmpty ||
      invalidCheckpoints.isNotEmpty ||
      incompleteOperations.isNotEmpty ||
      operationStorageIssues.isNotEmpty ||
      stagingFiles.isNotEmpty ||
      databaseCheck.length != 1 ||
      databaseCheck.first != 'ok';
  if (hasIssues) {
    if (missingSnapshotFiles.isNotEmpty) {
      print('Missing: ${missingSnapshotFiles.join(', ')}');
    }
    if (orphanedSnapshotFiles.isNotEmpty) {
      print('Orphaned: ${orphanedSnapshotFiles.join(', ')}');
    }
    for (final error in corruptSnapshotFiles) {
      print('Corrupt: $error');
    }
    if (stagingFiles.isNotEmpty) print('Staging: ${stagingFiles.join(', ')}');
    if (interruptedCheckpoints.isNotEmpty) {
      print('Interrupted checkpoints: ${interruptedCheckpoints.join(', ')}');
    }
    if (invalidCheckpoints.isNotEmpty) {
      print('Invalid checkpoints: ${invalidCheckpoints.join(', ')}');
    }
    if (incompleteOperations.isNotEmpty) {
      print(
        'Incomplete operations: ${incompleteOperations.map((operation) => '${operation.id} (${checkpointOperationStatusText(operation.status)})').join(', ')}',
      );
    }
    if (operationStorageIssues.isNotEmpty) {
      print('Operation storage: ${operationStorageIssues.join(', ')}');
    }
  }

  return hasIssues;
}
