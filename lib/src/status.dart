import 'dart:io';

import 'config.dart';
import 'checkpoint_repository.dart';
import 'checkpoint_operation_repository.dart';
import 'checkpoint_operation_models.dart';
import 'daemon.dart';
import 'database.dart';
import 'git_worktree.dart';
import 'ignore.dart';
import 'workspace.dart';
import 'watcher_control.dart';

Future<int> showStatus({
  String? basePath,
  String? homePath,
  DaemonPlatform? daemonPlatform,
}) async {
  final paths = DmcPaths(basePath: basePath);
  final dmcDirExists = await paths.dmcDirectory.exists();
  final daemonState = dmcDirExists
      ? await getDaemonState(basePath: paths.rootPath, platform: daemonPlatform)
      : (hasPidFile: false, pid: null, isRunning: false);

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return 1;
  }

  var dbSizeBytes = 0;
  var totalSnapshots = 0;
  String? checkpointSummary;
  String? agentSummary;
  String? operationSummary;
  if (dmcDirExists) {
    final dbFile = File(paths.dbPath);
    if (await dbFile.exists()) {
      dbSizeBytes = await dbFile.length();
    }

    final db = DmcDatabase(paths.dbPath);
    db.initialize();
    totalSnapshots = db.getHistoryCount();
    final checkpoints = CheckpointRepository(db);
    final checkpoint =
        checkpoints.getActiveCheckpoint() ?? checkpoints.getLatestCheckpoint();
    if (checkpoint != null) {
      final view = checkpoints.getView(checkpoint.id)!;
      checkpointSummary =
          '${checkpoint.id} (${checkpoint.status.name}; ${view.protectedFileCount} protected, ${view.changedFileCount} changed, ${checkpoint.exclusionCount} excluded, ${checkpoint.fatalErrorCount} fatal)';
      final agent = checkpoint.agent;
      if (agent != null) {
        agentSummary =
            '${agent.agent} (session ${agent.sessionId ?? 'unknown'}, turn ${agent.turnId ?? 'unknown'})';
      }
    }
    final incomplete = CheckpointOperationRepository(db).incomplete();
    if (incomplete.isNotEmpty) {
      final operation = incomplete.first;
      operationSummary =
          '${operation.id} (${checkpointOperationStatusText(operation.status)}; ${operation.direction.name}; checkpoint ${operation.checkpointId})';
    }
    db.close();
  }

  print('[DMC] Status');
  print('Initialized: ${dmcDirExists ? 'yes' : 'no'}');
  print('Vault path: ${paths.dmcPath}');
  print(
    daemonState.isRunning && daemonState.pid != null
        ? 'Watcher: Running (PID: ${daemonState.pid})'
        : 'Watcher: Stopped',
  );
  final live = dmcDirExists ? await queryWatcher(paths) : null;
  final health = dmcDirExists
      ? readControlJson(paths, 'watcher-health.json')
      : null;
  print('Protection: ${live?['ready'] == true ? 'ready' : 'not ready'}');
  if (dmcDirExists) {
    print(
      'Ignore policy: ${(await describeIgnorePolicy(paths.rootPath)).text}',
    );
    describeGitWorktree(paths.rootPath)?.lines.forEach(print);
  }
  if (live != null || health != null) {
    final state = live ?? health!;
    print('Last watcher state: ${state['phase']}');
    print('Capture errors: ${state['errors']}');
    print('Excluded paths: ${(state['exclusions'] as Map?)?.length ?? 0}');
  }
  print('DB size bytes: $dbSizeBytes');
  print('Total snapshots: $totalSnapshots');
  print('Checkpoint: ${checkpointSummary ?? 'none'}');
  if (agentSummary != null) print('Checkpoint agent: $agentSummary');
  print('Incomplete checkpoint operation: ${operationSummary ?? 'none'}');
  print('Retention hours: ${config.retentionHours}');
  print('Max file size KB: ${config.maxFileSizeKb}');
  print(
    'Global config: ${config.hasGlobalConfig ? config.globalConfigPath : 'not found'}',
  );
  print(
    'Local config: ${config.hasLocalConfig ? config.localConfigPath : 'not found'}',
  );
  return dmcDirExists ? 0 : 1;
}
