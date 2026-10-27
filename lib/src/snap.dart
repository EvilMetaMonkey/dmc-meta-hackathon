import 'config.dart';
import 'database.dart';
import 'ignore.dart';
import 'task.dart';
import 'watcher.dart';
import 'workspace.dart';
import 'workspace_scan.dart';

Future<int> takeManualSnapshot({String? basePath, String? homePath}) async {
  final paths = DmcPaths(basePath: basePath);
  if (!await paths.dmcDirectory.exists()) {
    print('[DMC] Error: DMC not initialized. Run "dmc init" first.');
    return 1;
  }

  late final DmcConfig config;
  try {
    config = await loadDmcConfig(basePath: paths.rootPath, homePath: homePath);
  } catch (e) {
    print('[DMC] Error loading config: $e');
    return 1;
  }

  final db = DmcDatabase(paths.dbPath);
  try {
    db.initialize();
    final policy = await loadIgnorePolicy(paths.rootPath);
    final watcher = DmcWatcher(
      targetPath: paths.rootPath,
      database: db,
      snapshotsPath: paths.snapshotsPath,
      ignoreRules: policy.rules,
      git: policy.git,
      maxFileSizeBytes: config.maxFileSizeBytes,
      activeTaskNameProvider: () =>
          readActiveTaskSync(basePath: paths.rootPath),
    );

    var processedFiles = 0;
    final scan = await scanWorkspacePolicy(paths, policy);
    var failedFiles = scan.errors.length;
    for (final error in scan.errors.entries) {
      print('[DMC] Scan failed ${error.key}: ${error.value}');
    }
    if (scan.errors.isNotEmpty) {
      print(
        '[DMC] Manual snapshot incomplete. Resolve scan/ignore errors before capturing.',
      );
      return 1;
    }
    for (final normalizedPath in scan.files) {
      processedFiles++;
      final result = await watcher.captureFileNow(normalizedPath);
      if (result.hadError) failedFiles++;
    }
    print(
      '[DMC] Excluded ${scan.exclusions.length} path(s) by ignore/link policy.',
    );

    if (failedFiles > 0) {
      print(
        '[DMC] Manual snapshot incomplete. Checked $processedFiles file(s), $failedFiles failed.',
      );
      return 1;
    }
    print('[DMC] Manual snapshot completed. Checked $processedFiles file(s).');
    return 0;
  } catch (e) {
    print('[DMC] Manual snapshot failed: $e');
    return 1;
  } finally {
    db.close();
  }
}
