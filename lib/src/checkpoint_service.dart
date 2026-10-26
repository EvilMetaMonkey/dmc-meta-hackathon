import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'checkpoint_models.dart';
import 'checkpoint_operation_repository.dart';
import 'checkpoint_repository.dart';
import 'config.dart';
import 'database.dart';
import 'file_policy.dart';
import 'ignore.dart';
import 'machine_output.dart';
import 'snapshot_store.dart';
import 'workspace.dart';
import 'workspace_scan.dart';
import 'workspace_operation_lock.dart';

typedef SnapshotStoreFactory =
    SnapshotStore Function(DmcDatabase database, String snapshotsPath);

int? _checkpointPermissionMode(FileStat stat) =>
    Platform.isWindows ? null : stat.mode & 0x1ff;

class _CapturedFile {
  final int snapshotId;
  final String hash;
  final int? mode;
  const _CapturedFile(this.snapshotId, this.hash, this.mode);
}

class CheckpointService {
  final String? basePath;
  final String? homePath;
  final SnapshotStoreFactory _storeFactory;
  final int Function() _now;
  final String Function(int timestamp) _idGenerator;

  CheckpointService({
    this.basePath,
    this.homePath,
    SnapshotStoreFactory? storeFactory,
    int Function()? now,
    String Function(int timestamp)? idGenerator,
  }) : _storeFactory =
           storeFactory ??
           ((database, snapshotsPath) =>
               SnapshotStore(database: database, snapshotsPath: snapshotsPath)),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _idGenerator = idGenerator ?? _newCheckpointId;

  static String _newCheckpointId(int timestamp) {
    final random = Random.secure();
    final suffix = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'cp_${timestamp.toRadixString(36)}_$suffix';
  }

  Future<CommandResult> begin({String? label, String source = 'manual'}) async {
    const command = 'checkpoint.begin';
    final normalizedSource = source.trim();
    final normalizedLabel = label?.trim();
    if (normalizedSource.isEmpty) {
      return machineFailure(
        command,
        2,
        'invalid_source',
        'Source cannot be empty.',
      );
    }
    if (normalizedLabel != null && normalizedLabel.isEmpty) {
      return machineFailure(
        command,
        2,
        'invalid_label',
        'Label cannot be empty.',
      );
    }

    final paths = DmcPaths(basePath: basePath);
    if (!paths.dmcDirectory.existsSync() || !File(paths.dbPath).existsSync()) {
      return machineFailure(
        command,
        1,
        'not_initialized',
        'DMC is not initialized. Run "dmc init" first.',
      );
    }

    final database = DmcDatabase(paths.dbPath);
    WorkspaceOperationLock? commandLock;
    String? checkpointId;
    var checkpointCreated = false;
    try {
      commandLock = WorkspaceOperationLock.acquire(paths);
      database.initialize();
      final repository = CheckpointRepository(database);
      final active = repository.getActiveCheckpoint();
      if (active != null) {
        return machineFailure(
          command,
          3,
          'checkpoint_already_active',
          'Checkpoint ${active.id} is ${active.status.name}. Close or release it before beginning another checkpoint.',
        );
      }

      final createdAt = _now();
      checkpointId = _idGenerator(createdAt);
      late final ({
        DmcConfig config,
        List<IgnoreRule> rules,
        String fingerprint,
      })
      policy;
      try {
        policy = await _loadPolicy(paths);
      } catch (error) {
        repository.createCheckpoint(
          id: checkpointId,
          label: normalizedLabel,
          source: normalizedSource,
          createdAt: createdAt,
          policyFingerprint: 'unavailable',
        );
        checkpointCreated = true;
        repository.addIssue(
          CheckpointIssue(
            checkpointId: checkpointId,
            phase: 'begin',
            filePath: null,
            code: 'policy_invalid',
            message: error.toString(),
            fatal: true,
          ),
        );
        repository.finishBegin(
          checkpointId,
          valid: false,
          fatalErrors: 1,
          exclusions: 0,
        );
        return _viewResult(
          command,
          repository.getView(checkpointId)!,
          exitCode: 3,
          includeFiles: false,
        );
      }
      repository.createCheckpoint(
        id: checkpointId,
        label: normalizedLabel,
        source: normalizedSource,
        createdAt: createdAt,
        policyFingerprint: policy.fingerprint,
      );
      checkpointCreated = true;

      final store = _storeFactory(database, paths.snapshotsPath);
      final issues = <CheckpointIssue>[];
      final before = <String, _CapturedFile>{};
      final scan = await scanWorkspace(paths, policy.rules);
      _recordScanIssues(repository, checkpointId, 'begin', scan, issues);
      if (scan.errors.isEmpty) {
        for (final filePath in [...scan.files]..sort()) {
          final relative = p.normalize(
            p.relative(filePath, from: paths.rootPath),
          );
          final captured = await _captureCurrent(
            paths,
            store,
            filePath,
            relative,
            policy.config.maxFileSizeBytes,
            checkpointId,
            'begin',
            repository,
            issues,
          );
          if (captured != null) {
            before[relative] = captured;
            repository.addBeforeFile(
              checkpointId: checkpointId,
              filePath: relative,
              snapshotId: captured.snapshotId,
              hash: captured.hash,
              mode: captured.mode,
            );
          }
        }
        await _verifyCurrentManifest(
          paths: paths,
          rules: policy.rules,
          config: policy.config,
          store: store,
          expected: before,
          checkpointId: checkpointId,
          phase: 'begin',
          repository: repository,
          issues: issues,
        );
      }

      final fatalCount = issues.where((issue) => issue.fatal).length;
      final exclusionCount = issues.where((issue) => !issue.fatal).length;
      repository.finishBegin(
        checkpointId,
        valid: fatalCount == 0,
        fatalErrors: fatalCount,
        exclusions: exclusionCount,
      );
      return _viewResult(
        command,
        repository.getView(checkpointId)!,
        exitCode: fatalCount == 0 ? 0 : 3,
        includeFiles: false,
      );
    } catch (error) {
      if (error is WorkspaceOperationBusy) {
        return machineFailure(
          command,
          3,
          'checkpoint_busy',
          'Another checkpoint command is running in this workspace.',
        );
      }
      if (checkpointCreated && checkpointId != null) {
        try {
          final repository = CheckpointRepository(database);
          repository.addIssue(
            CheckpointIssue(
              checkpointId: checkpointId,
              phase: 'begin',
              filePath: null,
              code: 'begin_failed',
              message: error.toString(),
              fatal: true,
            ),
          );
          final issues = repository.getIssues(checkpointId);
          repository.finishBegin(
            checkpointId,
            valid: false,
            fatalErrors: issues.where((issue) => issue.fatal).length,
            exclusions: issues.where((issue) => !issue.fatal).length,
          );
          return _viewResult(
            command,
            repository.getView(checkpointId)!,
            exitCode: 3,
            includeFiles: false,
          );
        } catch (_) {}
      }
      return machineFailure(command, 1, 'begin_failed', error.toString());
    } finally {
      database.close();
      commandLock?.close();
    }
  }

  Future<CommandResult> close(String id) async {
    const command = 'checkpoint.close';
    final paths = DmcPaths(basePath: basePath);
    final database = DmcDatabase(paths.dbPath);
    WorkspaceOperationLock? commandLock;
    try {
      if (!File(paths.dbPath).existsSync()) {
        return machineFailure(
          command,
          1,
          'not_initialized',
          'DMC is not initialized.',
        );
      }
      commandLock = WorkspaceOperationLock.acquire(paths);
      database.initialize();
      final repository = CheckpointRepository(database);
      var checkpoint = repository.getCheckpoint(id);
      if (checkpoint == null) {
        return machineFailure(
          command,
          5,
          'checkpoint_not_found',
          'Checkpoint $id was not found.',
        );
      }
      if (checkpoint.status == CheckpointStatus.closed) {
        return _viewResult(
          command,
          repository.getView(id)!,
          includeFiles: false,
        );
      }
      if (checkpoint.status != CheckpointStatus.open &&
          checkpoint.status != CheckpointStatus.closing) {
        return machineFailure(
          command,
          3,
          'checkpoint_not_open',
          'Checkpoint $id is ${checkpoint.status.name} and cannot be closed.',
        );
      }

      final policy = await _loadPolicy(paths);
      repository.prepareClose(id);
      final issues = repository.getIssues(id);
      if (policy.fingerprint != checkpoint.policyFingerprint) {
        _addIssue(
          repository,
          issues,
          checkpointId: id,
          phase: 'close',
          code: 'policy_changed',
          message:
              'Configuration or ignore policy changed after begin. Restore the original policy and begin a new checkpoint.',
          fatal: true,
        );
      } else {
        final store = _storeFactory(database, paths.snapshotsPath);
        final before = {
          for (final file in repository.getFiles(id))
            if (file.beforeKind == CheckpointFileKind.file &&
                file.beforeSnapshotId != null &&
                file.beforeHash != null)
              file.filePath: _CapturedFile(
                file.beforeSnapshotId!,
                file.beforeHash!,
                file.beforeMode,
              ),
        };
        final after = <String, _CapturedFile>{};
        final scan = await scanWorkspace(paths, policy.rules);
        _recordScanIssues(repository, id, 'close', scan, issues);
        if (scan.errors.isEmpty) {
          for (final filePath in [...scan.files]..sort()) {
            final relative = p.normalize(
              p.relative(filePath, from: paths.rootPath),
            );
            final captured = await _captureCurrent(
              paths,
              store,
              filePath,
              relative,
              policy.config.maxFileSizeBytes,
              id,
              'close',
              repository,
              issues,
            );
            if (captured == null) {
              if (before.containsKey(relative)) {
                _addIssue(
                  repository,
                  issues,
                  checkpointId: id,
                  phase: 'close',
                  filePath: relative,
                  code: 'protected_file_excluded',
                  message:
                      'A file protected at begin is no longer eligible for complete post-run capture.',
                  fatal: true,
                );
              }
              continue;
            }
            after[relative] = captured;
            final prior = before[relative];
            if (prior == null) {
              repository.addCreatedFile(
                checkpointId: id,
                filePath: relative,
                snapshotId: captured.snapshotId,
                hash: captured.hash,
                mode: captured.mode,
              );
            } else {
              repository.setAfterFile(
                checkpointId: id,
                filePath: relative,
                snapshotId: captured.snapshotId,
                hash: captured.hash,
                mode: captured.mode,
                change:
                    prior.hash == captured.hash && prior.mode == captured.mode
                    ? CheckpointChangeKind.unchanged
                    : CheckpointChangeKind.modified,
              );
            }
          }
          for (final relative in before.keys.where(
            (relative) => !after.containsKey(relative),
          )) {
            final absolute = p.join(paths.rootPath, relative);
            if (FileSystemEntity.typeSync(absolute, followLinks: false) ==
                FileSystemEntityType.notFound) {
              repository.setAfterAbsent(checkpointId: id, filePath: relative);
            }
          }
          await _verifyCurrentManifest(
            paths: paths,
            rules: policy.rules,
            config: policy.config,
            store: store,
            expected: after,
            expectedAbsent: before.keys.toSet().difference(after.keys.toSet()),
            checkpointId: id,
            phase: 'close',
            repository: repository,
            issues: issues,
          );
          _verifyStoredManifest(
            paths,
            repository.getFiles(id),
            repository,
            issues,
            id,
          );
        }
      }

      final finalIssues = repository.getIssues(id);
      final fatalCount = finalIssues.where((issue) => issue.fatal).length;
      final exclusionCount = finalIssues.where((issue) => !issue.fatal).length;
      repository.finishClose(
        id,
        valid: fatalCount == 0,
        closedAt: _now(),
        fatalErrors: fatalCount,
        exclusions: exclusionCount,
      );
      checkpoint = repository.getCheckpoint(id)!;
      return _viewResult(
        command,
        repository.getView(id)!,
        exitCode: checkpoint.status == CheckpointStatus.closed ? 0 : 3,
        includeFiles: false,
      );
    } catch (error) {
      if (error is WorkspaceOperationBusy) {
        return machineFailure(
          command,
          3,
          'checkpoint_busy',
          'Another checkpoint command is running in this workspace.',
        );
      }
      return machineFailure(command, 1, 'close_failed', error.toString());
    } finally {
      database.close();
      commandLock?.close();
    }
  }

  Future<CommandResult> show(String id) async => _readOnlyResult(
    'checkpoint.show',
    id,
    includeFiles: true,
    includeOperations: true,
    requireClosed: false,
  );

  Future<CommandResult> diff(String id) async => _readOnlyResult(
    'checkpoint.diff',
    id,
    includeFiles: true,
    includeOperations: false,
    requireClosed: true,
  );

  Future<CommandResult> list({int limit = 50}) async {
    const command = 'checkpoint.list';
    final paths = DmcPaths(basePath: basePath);
    final database = DmcDatabase(paths.dbPath);
    try {
      if (!File(paths.dbPath).existsSync()) {
        return machineFailure(
          command,
          1,
          'not_initialized',
          'DMC is not initialized.',
        );
      }
      if (limit < 1 || limit > 1000) {
        return machineFailure(
          command,
          2,
          'invalid_limit',
          'Checkpoint list limit must be between 1 and 1000.',
        );
      }
      database.initialize();
      final checkpoints = CheckpointRepository(database);
      final operations = CheckpointOperationRepository(database);
      final records = checkpoints.listCheckpoints(limit: limit);
      return CommandResult(
        command: command,
        exitCode: 0,
        data: {
          'limit': limit,
          'count': records.length,
          'checkpoints': [
            for (final checkpoint in records)
              _checkpointListItem(checkpoints, operations, checkpoint.id),
          ],
        },
      );
    } catch (error) {
      return machineFailure(
        command,
        1,
        'checkpoint_list_failed',
        error.toString(),
      );
    } finally {
      database.close();
    }
  }

  Future<CommandResult> release(String id) async {
    const command = 'checkpoint.release';
    final paths = DmcPaths(basePath: basePath);
    final database = DmcDatabase(paths.dbPath);
    WorkspaceOperationLock? commandLock;
    try {
      if (!File(paths.dbPath).existsSync()) {
        return machineFailure(
          command,
          1,
          'not_initialized',
          'DMC is not initialized.',
        );
      }
      commandLock = WorkspaceOperationLock.acquire(paths);
      database.initialize();
      final repository = CheckpointRepository(database);
      final checkpoint = repository.getCheckpoint(id);
      if (checkpoint == null) {
        return machineFailure(
          command,
          3,
          'checkpoint_not_found',
          'Checkpoint $id was not found.',
        );
      }
      if (checkpoint.status == CheckpointStatus.released) {
        return _viewResult(
          command,
          repository.getView(id)!,
          includeFiles: false,
        );
      }
      repository.release(id, _now());
      return _viewResult(command, repository.getView(id)!, includeFiles: false);
    } catch (error) {
      if (error is WorkspaceOperationBusy) {
        return machineFailure(
          command,
          3,
          'checkpoint_busy',
          'Another checkpoint command is running in this workspace.',
        );
      }
      if (error is StateError &&
          error.message.toString().contains('incomplete restore operation')) {
        return machineFailure(
          command,
          6,
          'operation_incomplete',
          error.message.toString(),
        );
      }
      return machineFailure(command, 1, 'release_failed', error.toString());
    } finally {
      database.close();
      commandLock?.close();
    }
  }

  Future<CommandResult> _readOnlyResult(
    String command,
    String id, {
    required bool includeFiles,
    required bool includeOperations,
    required bool requireClosed,
  }) async {
    final paths = DmcPaths(basePath: basePath);
    final database = DmcDatabase(paths.dbPath);
    try {
      if (!File(paths.dbPath).existsSync()) {
        return machineFailure(
          command,
          1,
          'not_initialized',
          'DMC is not initialized.',
        );
      }
      database.initialize();
      final repository = CheckpointRepository(database);
      final view = repository.getView(id);
      if (view == null) {
        return machineFailure(
          command,
          3,
          'checkpoint_not_found',
          'Checkpoint $id was not found.',
        );
      }
      if (requireClosed &&
          view.checkpoint.status != CheckpointStatus.closed &&
          view.checkpoint.status != CheckpointStatus.released) {
        return _viewResult(
          command,
          view,
          exitCode: 3,
          includeFiles: includeFiles,
          extraData: _operationData(database, id, include: includeOperations),
        );
      }
      return _viewResult(
        command,
        view,
        includeFiles: includeFiles,
        extraData: _operationData(database, id, include: includeOperations),
      );
    } catch (error) {
      return machineFailure(
        command,
        1,
        'checkpoint_read_failed',
        error.toString(),
      );
    } finally {
      database.close();
    }
  }

  Future<({DmcConfig config, List<IgnoreRule> rules, String fingerprint})>
  _loadPolicy(DmcPaths paths) async {
    final config = await loadDmcConfig(
      basePath: paths.rootPath,
      homePath: homePath,
    );
    final rules = await loadIgnoreRules(paths.rootPath, announce: false);
    final policy = jsonEncode({
      'version': 1,
      'maxFileSizeBytes': config.maxFileSizeBytes,
      'rules': [
        for (final rule in rules)
          {
            'pattern': rule.pattern,
            'directoryOnly': rule.directoryOnly,
            'matchAnywhere': rule.matchAnywhere,
            'hasWildcard': rule.hasWildcard,
          },
      ],
    });
    return (
      config: config,
      rules: rules,
      fingerprint: sha256.convert(utf8.encode(policy)).toString(),
    );
  }

  Future<_CapturedFile?> _captureCurrent(
    DmcPaths paths,
    SnapshotStore store,
    String filePath,
    String relative,
    int maxFileSizeBytes,
    String checkpointId,
    String phase,
    CheckpointRepository repository,
    List<CheckpointIssue> issues,
  ) async {
    if (hasKnownBinaryExtension(filePath)) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: relative,
        code: 'binary_file',
        message: 'Binary files are excluded from checkpoint protection.',
        fatal: false,
      );
      return null;
    }
    CaptureResult result = const CaptureResult(CaptureStatus.failed);
    for (var attempt = 0; attempt < 3; attempt++) {
      result = await store.captureFile(
        source: File(filePath),
        relativePath: relative,
        timestamp: _now(),
        maxFileSizeBytes: maxFileSizeBytes,
        skipContent: hasBinaryProbe,
        requireStableRead: true,
      );
      if (!result.hadError ||
          !(result.message?.startsWith('Source changed during capture') ??
              false)) {
        break;
      }
    }
    if (result.status == CaptureStatus.skipped) {
      final oversized = result.message == 'file exceeds max size';
      final binary = result.message == 'binary files are not tracked';
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: relative,
        code: oversized
            ? 'oversized_file'
            : (binary ? 'binary_file' : 'file_unavailable'),
        message: oversized
            ? 'File exceeds the configured checkpoint size limit.'
            : binary
            ? 'Binary files are excluded from checkpoint protection.'
            : 'File disappeared or became unavailable during capture.',
        fatal: !oversized && !binary,
      );
      return null;
    }
    if (result.hadError || result.snapshotId == null) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: relative,
        code: 'capture_failed',
        message:
            result.message ?? 'Capture did not produce a verified snapshot.',
        fatal: true,
      );
      return null;
    }
    final row = store.database.getSnapshotById(result.snapshotId!);
    if (row == null ||
        isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath)) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: relative,
        code: 'capture_failed',
        message: 'Capture did not preserve a present regular file.',
        fatal: true,
      );
      return null;
    }
    SnapshotStore.readVerifiedBytes(
      paths.snapshotsPath,
      row.snapshotPath,
      row.hash,
    );
    final stat = File(filePath).statSync();
    if (stat.type != FileSystemEntityType.file) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: relative,
        code: 'capture_failed',
        message: 'File disappeared before permissions could be recorded.',
        fatal: true,
      );
      return null;
    }
    return _CapturedFile(row.id, row.hash, _checkpointPermissionMode(stat));
  }

  Future<void> _verifyCurrentManifest({
    required DmcPaths paths,
    required List<IgnoreRule> rules,
    required DmcConfig config,
    required SnapshotStore store,
    required Map<String, _CapturedFile> expected,
    Set<String> expectedAbsent = const {},
    required String checkpointId,
    required String phase,
    required CheckpointRepository repository,
    required List<CheckpointIssue> issues,
  }) async {
    final verification = await scanWorkspace(paths, rules);
    _recordScanIssues(repository, checkpointId, phase, verification, issues);
    if (verification.errors.isNotEmpty) return;
    final actual = <String, _CapturedFile>{};
    for (final filePath in [...verification.files]..sort()) {
      final relative = p.normalize(p.relative(filePath, from: paths.rootPath));
      final captured = await _captureCurrent(
        paths,
        store,
        filePath,
        relative,
        config.maxFileSizeBytes,
        checkpointId,
        phase,
        repository,
        issues,
      );
      if (captured != null) actual[relative] = captured;
    }
    final pathsToCompare = {...expected.keys, ...actual.keys};
    for (final relative in pathsToCompare) {
      if (expectedAbsent.contains(relative) && !actual.containsKey(relative)) {
        continue;
      }
      final expectedFile = expected[relative];
      final actualFile = actual[relative];
      if (expectedFile == null ||
          actualFile == null ||
          expectedFile.hash != actualFile.hash ||
          expectedFile.mode != actualFile.mode) {
        _addIssue(
          repository,
          issues,
          checkpointId: checkpointId,
          phase: phase,
          filePath: relative,
          code: 'manifest_changed',
          message:
              'Workspace changed while the $phase manifest was being verified. Stop writers and create a new checkpoint.',
          fatal: true,
        );
      }
    }
  }

  void _verifyStoredManifest(
    DmcPaths paths,
    List<CheckpointFileRecord> files,
    CheckpointRepository repository,
    List<CheckpointIssue> issues,
    String checkpointId,
  ) {
    for (final file in files) {
      for (final state in [
        (id: file.beforeSnapshotId, hash: file.beforeHash),
        (id: file.afterSnapshotId, hash: file.afterHash),
      ]) {
        if (state.id == null) continue;
        final row = repository.database.getSnapshotById(state.id!);
        try {
          if (row == null || row.hash != state.hash) {
            throw const SnapshotIntegrityException(
              'Checkpoint snapshot metadata mismatch.',
            );
          }
          SnapshotStore.readVerifiedBytes(
            paths.snapshotsPath,
            row.snapshotPath,
            row.hash,
          );
        } catch (error) {
          _addIssue(
            repository,
            issues,
            checkpointId: checkpointId,
            phase: 'close',
            filePath: file.filePath,
            code: 'snapshot_corrupt',
            message: error.toString(),
            fatal: true,
          );
        }
      }
    }
  }

  void _recordScanIssues(
    CheckpointRepository repository,
    String checkpointId,
    String phase,
    WorkspaceScan scan,
    List<CheckpointIssue> issues,
  ) {
    for (final entry in scan.exclusions.entries) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: entry.key,
        code: entry.value == 'symlink' ? 'symlink' : 'ignored_path',
        message: entry.value == 'symlink'
            ? 'Symlinks are excluded from checkpoint protection.'
            : 'Path is excluded by checkpoint ignore policy.',
        fatal: false,
      );
    }
    for (final entry in scan.errors.entries) {
      _addIssue(
        repository,
        issues,
        checkpointId: checkpointId,
        phase: phase,
        filePath: entry.key == '.' ? null : entry.key,
        code: entry.value.contains('Nested .gitignore')
            ? 'nested_ignore'
            : 'scan_failed',
        message: entry.value,
        fatal: true,
      );
    }
  }

  void _addIssue(
    CheckpointRepository repository,
    List<CheckpointIssue> issues, {
    required String checkpointId,
    required String phase,
    required String code,
    required String message,
    required bool fatal,
    String? filePath,
  }) {
    if (issues.any(
      (issue) =>
          issue.phase == phase &&
          issue.filePath == filePath &&
          issue.code == code &&
          issue.message == message,
    )) {
      return;
    }
    final issue = CheckpointIssue(
      checkpointId: checkpointId,
      phase: phase,
      filePath: filePath,
      code: code,
      message: message,
      fatal: fatal,
    );
    issues.add(issue);
    repository.addIssue(issue);
  }

  CommandResult _viewResult(
    String command,
    CheckpointView view, {
    int exitCode = 0,
    required bool includeFiles,
    Map<String, Object?> extraData = const {},
  }) {
    final warnings = view.issues
        .where((issue) => !issue.fatal)
        .map(
          (issue) =>
              MachineMessage(issue.code, issue.message, path: issue.filePath),
        )
        .toList();
    final errors = view.issues
        .where((issue) => issue.fatal)
        .map(
          (issue) =>
              MachineMessage(issue.code, issue.message, path: issue.filePath),
        )
        .toList();
    if (exitCode != 0 && errors.isEmpty) {
      errors.add(
        MachineMessage(
          'checkpoint_incomplete',
          'Checkpoint ${view.checkpoint.id} is ${view.checkpoint.status.name}.',
        ),
      );
    }
    return CommandResult(
      command: command,
      exitCode: exitCode,
      data: {
        ...view.toJson(includeFiles: includeFiles),
        ...extraData,
      },
      warnings: warnings,
      errors: errors,
    );
  }

  Map<String, Object?> _operationData(
    DmcDatabase database,
    String checkpointId, {
    required bool include,
  }) => include
      ? {
          'operations': CheckpointOperationRepository(database)
              .forCheckpoint(checkpointId)
              .map((operation) => operation.toJson())
              .toList(),
        }
      : const {};

  Map<String, Object?> _checkpointListItem(
    CheckpointRepository checkpoints,
    CheckpointOperationRepository operations,
    String checkpointId,
  ) {
    final summary =
        checkpoints
                .getView(checkpointId)!
                .toJson(includeFiles: false)['checkpoint']!
            as Map<String, Object?>;
    return {
      ...summary,
      'operations': operations
          .forCheckpoint(checkpointId)
          .map((operation) => operation.toJson())
          .toList(),
    };
  }
}

/// Human-readable agent context for a checkpoint's JSON `agent` object.
List<String> checkpointAgentLines(Map<dynamic, dynamic> agent) {
  final bytes = agent['transcriptBytes'];
  final sha256 = agent['transcriptSha256'];
  return [
    'Agent: ${agent['name']}; session: ${agent['sessionId'] ?? '(unknown)'}; turn: ${agent['turnId'] ?? '(unknown)'}',
    'Transcript: ${agent['transcriptPath'] ?? '(unknown)'}${bytes == null ? '' : ' ($bytes bytes, sha256 $sha256)'}',
  ];
}

List<String> checkpointHumanLines(CommandResult result) {
  final lines = <String>[];
  final checkpoints = result.data['checkpoints'];
  if (checkpoints is List) {
    lines.add('[DMC] Checkpoints: ${checkpoints.length}');
    for (final item in checkpoints.whereType<Map>()) {
      final agent = item['agent'];
      lines.add(
        '${item['id']}  ${item['status']}  ${item['changedFileCount'] ?? 0} changed  ${item['label'] ?? '(no label)'}${agent is Map ? '  [${agent['name']}]' : ''}',
      );
    }
  }
  final checkpoint = result.data['checkpoint'];
  if (checkpoint is Map) {
    final id = checkpoint['id'];
    final status = checkpoint['status'];
    lines.add('[DMC] Checkpoint $id: $status');
    lines.add(
      'Protected files: ${checkpoint['protectedFileCount'] ?? 0}; changed files: ${checkpoint['changedFileCount'] ?? 0}; exclusions: ${checkpoint['exclusionCount'] ?? 0}; fatal errors: ${checkpoint['fatalErrorCount'] ?? 0}',
    );
    if (result.command == 'checkpoint.show') {
      lines.add(
        'Source: ${checkpoint['source']}; label: ${checkpoint['label'] ?? '(none)'}',
      );
      final agent = checkpoint['agent'];
      if (agent is Map) lines.addAll(checkpointAgentLines(agent));
    }
    final files = result.data['files'];
    if (files is List) {
      for (final file in files.whereType<Map>()) {
        if (result.command == 'checkpoint.show') {
          final after = file['after'] as Map?;
          lines.add(
            '${file['path']}: ${file['change'] ?? 'protected'} (before ${(file['before'] as Map)['kind']}, after ${after?['kind'] ?? 'pending'})',
          );
        } else if (file['change'] != null && file['change'] != 'unchanged') {
          lines.add('${file['change']}: ${file['path']}');
        }
      }
    }
  }
  for (final warning in result.warnings) {
    lines.add(
      '[DMC] Excluded${warning.path == null ? '' : ' ${warning.path}'}: ${warning.message}',
    );
  }
  for (final error in result.errors) {
    lines.add(
      '[DMC] Error${error.path == null ? '' : ' ${error.path}'}: ${error.message}',
    );
  }
  if (result.command == 'checkpoint.begin' && result.ok && checkpoint is Map) {
    lines.add('Checkpoint is open. Agent work may begin.');
  } else if (result.command == 'checkpoint.close' && result.ok) {
    lines.add('Checkpoint closed with a verified post-run manifest.');
  } else if (result.command == 'checkpoint.release' && result.ok) {
    lines.add('Checkpoint content is released from retention pinning.');
  }
  return lines;
}
