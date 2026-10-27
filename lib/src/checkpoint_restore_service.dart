import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'checkpoint_models.dart';
import 'checkpoint_operation_models.dart';
import 'checkpoint_operation_repository.dart';
import 'checkpoint_plan.dart';
import 'checkpoint_repository.dart';
import 'database.dart';
import 'git_ignore.dart';
import 'machine_output.dart';
import 'snapshot_store.dart';
import 'watcher_control.dart';
import 'workspace.dart';
import 'workspace_operation_lock.dart';

typedef OperationStepHook =
    FutureOr<void> Function(int sequence, String filePath);

class CheckpointRestoreService {
  final String? basePath;
  final int Function() _now;
  final String Function(int timestamp) _idGenerator;
  final OperationStepHook? beforeApplyStep;
  final OperationStepHook? beforeRollbackStep;

  /// Finds Git for Git-mode ignore checks; tests can make it fail.
  final GitLocator? gitLocator;

  CheckpointRestoreService({
    this.basePath,
    this.gitLocator,
    int Function()? now,
    String Function(int timestamp)? idGenerator,
    this.beforeApplyStep,
    this.beforeRollbackStep,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _idGenerator = idGenerator ?? _newOperationId;

  static String _newOperationId(int timestamp) {
    final random = Random.secure();
    final suffix = List.generate(
      12,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return 'op_${timestamp.toRadixString(36)}_$suffix';
  }

  Future<CommandResult> restore(String checkpointId, {bool apply = false}) =>
      _runCheckpoint(
        checkpointId,
        CheckpointOperationDirection.restore,
        apply: apply,
      );

  Future<CommandResult> redo(String checkpointId, {bool apply = false}) =>
      _runCheckpoint(
        checkpointId,
        CheckpointOperationDirection.redo,
        apply: apply,
      );

  Future<CommandResult> _runCheckpoint(
    String checkpointId,
    CheckpointOperationDirection direction, {
    required bool apply,
  }) async {
    final command = 'checkpoint.${direction.name}';
    final paths = DmcPaths(basePath: basePath);
    if (!File(paths.dbPath).existsSync()) {
      return machineFailure(
        command,
        1,
        'not_initialized',
        'DMC is not initialized.',
      );
    }
    WorkspaceOperationLock? lock;
    final database = DmcDatabase(paths.dbPath);
    try {
      if (apply) {
        lock = WorkspaceOperationLock.acquire(paths);
        if (await queryWatcher(paths) != null) {
          return machineFailure(
            command,
            4,
            'watcher_running',
            'Stop the DMC watcher before applying a checkpoint.',
          );
        }
        _validateRecoveryRoot(paths);
      }
      database.initialize();
      final checkpoints = CheckpointRepository(database);
      final operations = CheckpointOperationRepository(database);
      // In a Git work tree, ask Git which checkpoint paths it ignores now.
      final git = await GitWorkTree.detect(paths.rootPath, locator: gitLocator);
      Future<CheckpointPlan> buildPlan() async => CheckpointPlanner(
        paths: paths,
        database: database,
        checkpoints: checkpoints,
        operations: operations,
        gitIgnored: git == null
            ? const {}
            : await git.ignoredAmong(
                checkpoints.getFiles(checkpointId).map((file) => file.filePath),
              ),
      ).build(checkpointId, direction);
      var plan = await buildPlan();
      if (!apply || !plan.canApply) {
        return _planResult(
          command,
          plan,
          applied: false,
          mode: apply ? 'apply' : 'preview',
        );
      }
      if (plan.actions.isEmpty) {
        return _planResult(
          command,
          plan,
          applied: true,
          mode: 'apply',
          noOp: true,
        );
      }

      final captured = <String, ({int? id, WorkspaceFileState state})>{};
      final store = SnapshotStore(
        database: database,
        snapshotsPath: paths.snapshotsPath,
      );
      for (final action in plan.actions) {
        final state = readWorkspaceState(paths, action.filePath);
        if (!state.matches(
          action.expectedKind,
          action.expectedHash,
          action.expectedMode,
        )) {
          return _singleIssueResult(
            command,
            4,
            'workspace_drift',
            'Workspace changed while the operation was being prepared.',
            path: action.filePath,
          );
        }
        int? snapshotId;
        if (state.kind == CheckpointFileKind.file) {
          final capture = await store.captureFile(
            source: paths.resolveFile(action.filePath).file,
            relativePath: action.filePath,
            timestamp: _now(),
            requireStableRead: true,
          );
          if (capture.hadError || capture.snapshotId == null) {
            return _singleIssueResult(
              command,
              4,
              'prestate_capture_failed',
              capture.message ?? 'Could not capture the current file state.',
              path: action.filePath,
            );
          }
          final row = database.getSnapshotById(capture.snapshotId!);
          if (row == null || row.hash != state.hash) {
            return _singleIssueResult(
              command,
              4,
              'workspace_drift',
              'Workspace changed while the operation was being prepared.',
              path: action.filePath,
            );
          }
          snapshotId = row.id;
        }
        captured[action.filePath] = (id: snapshotId, state: state);
      }

      // Capture writes only immutable vault data. Repeat the pure preflight
      // before committing the journal and before the first workspace mutation.
      plan = await buildPlan();
      if (!plan.canApply) {
        return _planResult(command, plan, applied: false, mode: 'apply');
      }
      for (final action in plan.actions) {
        final pre = captured[action.filePath];
        if (pre == null ||
            !pre.state.matches(
              action.expectedKind,
              action.expectedHash,
              action.expectedMode,
            )) {
          return _singleIssueResult(
            command,
            4,
            'workspace_drift',
            'The prepared operation no longer matches the workspace.',
            path: action.filePath,
          );
        }
      }

      final createdAt = _now();
      final operationId = _idGenerator(createdAt);
      final operation = CheckpointOperationRecord(
        id: operationId,
        checkpointId: checkpointId,
        direction: direction,
        status: CheckpointOperationStatus.planned,
        createdAt: createdAt,
        startedAt: null,
        completedAt: null,
        failureMessage: null,
      );
      final files = [
        for (final action in plan.actions)
          CheckpointOperationFileRecord(
            operationId: operationId,
            sequence: action.sequence,
            filePath: action.filePath,
            expectedKind: action.expectedKind,
            expectedHash: action.expectedHash,
            expectedMode: action.expectedMode,
            intendedKind: action.intendedKind,
            intendedSnapshotId: action.intendedSnapshotId,
            intendedHash: action.intendedHash,
            intendedMode: action.intendedMode,
            preKind: captured[action.filePath]!.state.kind,
            preSnapshotId: captured[action.filePath]!.id,
            preHash: captured[action.filePath]!.state.hash,
            preMode: captured[action.filePath]!.state.mode,
            status: CheckpointOperationFileStatus.pending,
            error: null,
            recoveryName:
                '${action.sequence.toString().padLeft(6, '0')}.original',
          ),
      ];
      operations.create(operation, files);
      operations.setStatus(
        operationId,
        CheckpointOperationStatus.applying,
        startedAt: _now(),
      );
      try {
        await _applyFiles(paths, database, operations, operationId, files);
        _verifyFinalState(paths, files, intended: true);
        operations.setStatus(
          operationId,
          CheckpointOperationStatus.completed,
          completedAt: _now(),
        );
        _cleanupRecovery(paths, operationId);
        return CommandResult(
          command: command,
          exitCode: 0,
          data: {
            ...plan.toJson(),
            'mode': 'apply',
            'applied': true,
            'operationId': operationId,
            'operation': operations.get(operationId)!.toJson(),
          },
        );
      } catch (error) {
        operations.setStatus(
          operationId,
          CheckpointOperationStatus.failed,
          failureMessage: error.toString(),
        );
        return CommandResult(
          command: command,
          exitCode: 6,
          data: {
            ...plan.toJson(),
            'mode': 'apply',
            'applied': false,
            'operationId': operationId,
            'operation': operations.get(operationId)!.toJson(),
          },
          errors: [
            MachineMessage(
              'operation_interrupted',
              'Operation $operationId is incomplete: $error Use checkpoint recover.',
            ),
          ],
        );
      }
    } on WorkspaceOperationBusy {
      return machineFailure(
        command,
        6,
        'operation_busy',
        'Another checkpoint operation is running in this workspace.',
      );
    } on GitIgnoreException catch (error) {
      return machineFailure(command, 1, error.code, error.message);
    } catch (error) {
      return machineFailure(command, 1, 'operation_failed', error.toString());
    } finally {
      database.close();
      lock?.close();
    }
  }

  Future<CommandResult> recover(
    String operationId, {
    required bool rollback,
    bool preview = false,
  }) async {
    const command = 'checkpoint.recover';
    final paths = DmcPaths(basePath: basePath);
    if (!File(paths.dbPath).existsSync()) {
      return machineFailure(
        command,
        1,
        'not_initialized',
        'DMC is not initialized.',
      );
    }
    WorkspaceOperationLock? lock;
    final database = DmcDatabase(paths.dbPath);
    try {
      lock = WorkspaceOperationLock.acquire(paths, readOnly: preview);
      _validateRecoveryRoot(paths);
      if (await queryWatcher(paths) != null) {
        return machineFailure(
          command,
          4,
          'watcher_running',
          'Stop the DMC watcher before recovering an operation.',
        );
      }
      if (preview) {
        database.openReadOnly();
      } else {
        database.initialize();
      }
      final operations = CheckpointOperationRepository(database);
      final view = operations.getView(operationId);
      if (view == null) {
        return machineFailure(
          command,
          3,
          'operation_not_found',
          'Operation $operationId was not found.',
        );
      }
      if ({
        CheckpointOperationStatus.completed,
        CheckpointOperationStatus.rolledBack,
      }.contains(view.operation.status)) {
        return machineFailure(
          command,
          3,
          'operation_not_recoverable',
          'Operation $operationId is already ${checkpointOperationStatusText(view.operation.status)}.',
        );
      }
      if (view.operation.status == CheckpointOperationStatus.rollingBack &&
          !rollback) {
        return machineFailure(
          command,
          3,
          'rollback_incomplete',
          'Operation $operationId has an interrupted rollback. Continue with --rollback.',
        );
      }
      final observedStates = <String, WorkspaceFileState>{};
      final conflicts = _recoveryPreflight(
        paths,
        database,
        operationId,
        view.files,
        rollback: rollback,
        observedStates: preview ? observedStates : null,
      );
      if (preview) {
        final actions = <Map<String, Object?>>[];
        for (final file in view.files) {
          final current = observedStates[file.filePath];
          final target = WorkspaceFileState(
            rollback ? file.preKind : file.intendedKind,
            rollback ? file.preHash : file.intendedHash,
            rollback ? file.preMode : file.intendedMode,
          );
          actions.add({
            'sequence': file.sequence,
            'path': file.filePath,
            'current': current?.toJson(),
            'pre': WorkspaceFileState(
              file.preKind,
              file.preHash,
              file.preMode,
            ).toJson(),
            'target': target.toJson(),
            'noOp':
                current?.matches(target.kind, target.hash, target.mode) ??
                false,
          });
        }
        return CommandResult(
          command: command,
          exitCode: conflicts.isEmpty
              ? 0
              : conflicts.any((issue) => issue.code.contains('snapshot'))
              ? 5
              : 4,
          data: {
            'preview': true,
            'applied': false,
            'canRecover': conflicts.isEmpty,
            'operation': view.operation.toJson(),
            'operationId': operationId,
            'checkpointId': view.operation.checkpointId,
            'mode': rollback ? 'rollback' : 'resume',
            'actions': actions,
            'conflicts': conflicts.map((issue) => issue.toJson()).toList(),
          },
          errors: [
            for (final issue in conflicts)
              MachineMessage(issue.code, issue.message, path: issue.path),
          ],
        );
      }
      if (conflicts.isNotEmpty) {
        return CommandResult(
          command: command,
          exitCode: conflicts.any((issue) => issue.code.contains('snapshot'))
              ? 5
              : 4,
          data: {
            'operation': view.operation.toJson(),
            'operationId': operationId,
            'mode': rollback ? 'rollback' : 'resume',
            'conflicts': conflicts.map((issue) => issue.toJson()).toList(),
          },
          errors: [
            for (final issue in conflicts)
              MachineMessage(issue.code, issue.message, path: issue.path),
          ],
        );
      }
      operations.setStatus(
        operationId,
        rollback
            ? CheckpointOperationStatus.rollingBack
            : CheckpointOperationStatus.applying,
        startedAt: _now(),
      );
      try {
        if (rollback) {
          await _rollbackFiles(
            paths,
            database,
            operations,
            operationId,
            view.files.reversed.toList(),
          );
          _verifyFinalState(paths, view.files, intended: false);
        } else {
          await _applyFiles(
            paths,
            database,
            operations,
            operationId,
            view.files,
          );
          _verifyFinalState(paths, view.files, intended: true);
        }
        final finalStatus = rollback
            ? CheckpointOperationStatus.rolledBack
            : CheckpointOperationStatus.completed;
        operations.setStatus(operationId, finalStatus, completedAt: _now());
        _cleanupRecovery(paths, operationId);
        return CommandResult(
          command: command,
          exitCode: 0,
          data: {
            'mode': rollback ? 'rollback' : 'resume',
            'operationId': operationId,
            'operation': operations.get(operationId)!.toJson(),
          },
        );
      } catch (error) {
        operations.setStatus(
          operationId,
          rollback
              ? CheckpointOperationStatus.rollingBack
              : CheckpointOperationStatus.failed,
          failureMessage: error.toString(),
        );
        return CommandResult(
          command: command,
          exitCode: 6,
          data: {
            'mode': rollback ? 'rollback' : 'resume',
            'operationId': operationId,
            'operation': operations.get(operationId)!.toJson(),
          },
          errors: [
            MachineMessage(
              'recovery_interrupted',
              'Recovery of $operationId is incomplete: $error',
            ),
          ],
        );
      }
    } on WorkspaceOperationBusy {
      return machineFailure(
        command,
        6,
        'operation_busy',
        'Another checkpoint operation is running in this workspace.',
      );
    } catch (error) {
      return machineFailure(command, 1, 'recovery_failed', error.toString());
    } finally {
      database.close();
      lock?.close();
    }
  }

  Future<void> _applyFiles(
    DmcPaths paths,
    DmcDatabase database,
    CheckpointOperationRepository operations,
    String operationId,
    List<CheckpointOperationFileRecord> files,
  ) async {
    for (final file in files) {
      try {
        final current = readWorkspaceState(paths, file.filePath);
        if (current.matches(
          file.intendedKind,
          file.intendedHash,
          file.intendedMode,
        )) {
          operations.setFileStatus(
            operationId,
            file.filePath,
            CheckpointOperationFileStatus.applied,
          );
          continue;
        }
        if (current.matchesContent(file.intendedKind, file.intendedHash)) {
          await beforeApplyStep?.call(file.sequence, file.filePath);
          _setPermissionMode(
            paths.resolveFile(file.filePath).absolutePath,
            file.intendedMode,
          );
          final completed = readWorkspaceState(paths, file.filePath);
          if (!completed.matches(
            file.intendedKind,
            file.intendedHash,
            file.intendedMode,
          )) {
            throw FileSystemException(
              'Applied file permissions failed verification',
              file.filePath,
            );
          }
          operations.setFileStatus(
            operationId,
            file.filePath,
            CheckpointOperationFileStatus.applied,
          );
          continue;
        }
        final recovery = _recoveryFile(paths, operationId, file.recoveryName);
        final recoveryExists = _regularFileExists(recovery);
        final mayContinue =
            current.matches(file.preKind, file.preHash, file.preMode) ||
            (current.kind == CheckpointFileKind.absent && recoveryExists);
        if (!mayContinue) {
          throw FileSystemException(
            'Workspace drift detected during apply',
            file.filePath,
          );
        }
        await beforeApplyStep?.call(file.sequence, file.filePath);
        if (!recoveryExists && current.kind == CheckpointFileKind.file) {
          recovery.parent.createSync(recursive: true);
          paths.resolveFile(file.filePath).file.renameSync(recovery.path);
        }
        if (file.intendedKind == CheckpointFileKind.file) {
          final bytes = _verifiedSnapshot(
            database,
            paths,
            file.filePath,
            file.intendedSnapshotId,
            file.intendedHash,
          );
          _writeAtomic(paths, file.filePath, bytes, file.intendedMode);
        }
        final after = readWorkspaceState(paths, file.filePath);
        if (!after.matches(
          file.intendedKind,
          file.intendedHash,
          file.intendedMode,
        )) {
          throw FileSystemException(
            'Applied file failed verification',
            file.filePath,
          );
        }
        operations.setFileStatus(
          operationId,
          file.filePath,
          CheckpointOperationFileStatus.applied,
        );
      } catch (error) {
        operations.setFileStatus(
          operationId,
          file.filePath,
          file.status,
          error: error.toString(),
        );
        rethrow;
      }
    }
  }

  Future<void> _rollbackFiles(
    DmcPaths paths,
    DmcDatabase database,
    CheckpointOperationRepository operations,
    String operationId,
    List<CheckpointOperationFileRecord> files,
  ) async {
    for (final file in files) {
      try {
        final current = readWorkspaceState(paths, file.filePath);
        if (current.matches(file.preKind, file.preHash, file.preMode)) {
          operations.setFileStatus(
            operationId,
            file.filePath,
            CheckpointOperationFileStatus.rolledBack,
          );
          continue;
        }
        await beforeRollbackStep?.call(file.sequence, file.filePath);
        final recovery = _recoveryFile(paths, operationId, file.recoveryName);
        final target = paths.resolveFile(file.filePath).file;
        if (current.kind == CheckpointFileKind.file) {
          recovery.parent.createSync(recursive: true);
          final discard = File('${recovery.path}.discard');
          if (discard.existsSync()) discard.deleteSync();
          target.renameSync(discard.path);
        }
        if (file.preKind == CheckpointFileKind.file) {
          if (_regularFileExists(recovery)) {
            _ensureTargetParent(paths, file.filePath);
            recovery.renameSync(target.path);
            _setPermissionMode(target.path, file.preMode);
          } else {
            final bytes = _verifiedSnapshot(
              database,
              paths,
              file.filePath,
              file.preSnapshotId,
              file.preHash,
            );
            _writeAtomic(paths, file.filePath, bytes, file.preMode);
          }
        }
        final after = readWorkspaceState(paths, file.filePath);
        if (!after.matches(file.preKind, file.preHash, file.preMode)) {
          throw FileSystemException(
            'Rolled-back file failed verification',
            file.filePath,
          );
        }
        operations.setFileStatus(
          operationId,
          file.filePath,
          CheckpointOperationFileStatus.rolledBack,
        );
      } catch (error) {
        operations.setFileStatus(
          operationId,
          file.filePath,
          file.status,
          error: error.toString(),
        );
        rethrow;
      }
    }
  }

  List<CheckpointPlanIssue> _recoveryPreflight(
    DmcPaths paths,
    DmcDatabase database,
    String operationId,
    List<CheckpointOperationFileRecord> files, {
    required bool rollback,
    Map<String, WorkspaceFileState>? observedStates,
  }) {
    final issues = <CheckpointPlanIssue>[];
    for (final file in files) {
      try {
        final current = readWorkspaceState(paths, file.filePath);
        observedStates?[file.filePath] = current;
        if (!rollback && file.intendedKind == CheckpointFileKind.file) {
          _verifiedSnapshot(
            database,
            paths,
            file.filePath,
            file.intendedSnapshotId,
            file.intendedHash,
          );
        }
        if (rollback && file.preKind == CheckpointFileKind.file) {
          final recovery = _recoveryFile(paths, operationId, file.recoveryName);
          if (!_regularFileExists(recovery)) {
            _verifiedSnapshot(
              database,
              paths,
              file.filePath,
              file.preSnapshotId,
              file.preHash,
            );
          } else if (sha256.convert(recovery.readAsBytesSync()).toString() !=
              file.preHash) {
            throw const SnapshotIntegrityException(
              'Recovery pre-state hash does not match the journal.',
            );
          }
        }
        final recovery = _recoveryFile(paths, operationId, file.recoveryName);
        final recoveryExists = _regularFileExists(recovery);
        final discardExists = _regularFileExists(
          File('${recovery.path}.discard'),
        );
        final allowed =
            current.matches(file.preKind, file.preHash, file.preMode) ||
            current.matches(
              file.intendedKind,
              file.intendedHash,
              file.intendedMode,
            ) ||
            current.matchesContent(file.intendedKind, file.intendedHash) ||
            (current.kind == CheckpointFileKind.absent &&
                (recoveryExists || (rollback && discardExists)));
        if (!allowed) {
          issues.add(
            CheckpointPlanIssue(
              'workspace_drift',
              'Current state is neither the recorded pre-state nor intended state.',
              path: file.filePath,
            ),
          );
        }
      } on SnapshotIntegrityException catch (error) {
        issues.add(
          CheckpointPlanIssue(
            'snapshot_unavailable',
            error.toString(),
            path: file.filePath,
          ),
        );
      } catch (error) {
        issues.add(
          CheckpointPlanIssue(
            'workspace_unavailable',
            error.toString(),
            path: file.filePath,
          ),
        );
      }
    }
    return issues;
  }

  List<int> _verifiedSnapshot(
    DmcDatabase database,
    DmcPaths paths,
    String filePath,
    int? snapshotId,
    String? hash,
  ) {
    if (snapshotId == null || hash == null) {
      throw const SnapshotIntegrityException('Snapshot reference is missing.');
    }
    final row = database.getSnapshotById(snapshotId);
    if (row == null || row.filePath != filePath || row.hash != hash) {
      throw SnapshotIntegrityException(
        'Snapshot $snapshotId does not match $filePath.',
      );
    }
    return SnapshotStore.readVerifiedBytes(
      paths.snapshotsPath,
      row.snapshotPath,
      row.hash,
    );
  }

  File _recoveryFile(DmcPaths paths, String operationId, String name) {
    if (!RegExp(r'^op_[a-z0-9]+_[0-9a-f]+$').hasMatch(operationId) ||
        p.basename(name) != name ||
        name.contains('\\')) {
      throw ArgumentError('Invalid operation recovery path.');
    }
    final path = paths.validateInternalPath(
      p.join(paths.operationsPath, operationId, name),
    );
    return File(path);
  }

  bool _regularFileExists(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return false;
    if (type != FileSystemEntityType.file) {
      throw FileSystemException(
        'Recovery entry is not a regular file',
        file.path,
      );
    }
    return true;
  }

  void _ensureTargetParent(DmcPaths paths, String filePath) {
    final target = validateWorkspaceFileTarget(paths, filePath);
    Directory(p.dirname(target.absolutePath)).createSync(recursive: true);
    paths.resolveFile(filePath);
  }

  void _validateRecoveryRoot(DmcPaths paths) {
    final recoveryPath = paths.operationsPath;
    final type = FileSystemEntity.typeSync(recoveryPath, followLinks: false);
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Operation recovery storage must be a directory',
        recoveryPath,
      );
    }
  }

  void _writeAtomic(
    DmcPaths paths,
    String filePath,
    List<int> bytes,
    int? mode,
  ) {
    _ensureTargetParent(paths, filePath);
    final target = paths.resolveFile(filePath).file;
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Atomic destination is not absent',
        target.path,
      );
    }
    final parent = Directory(p.dirname(target.path));
    final staging = parent.createTempSync('.dmc-restore-');
    try {
      final temporary = File(p.join(staging.path, 'content'));
      final handle = temporary.openSync(mode: FileMode.write);
      try {
        handle.writeFromSync(bytes);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      paths.resolveFile(filePath);
      temporary.renameSync(target.path);
      _setPermissionMode(target.path, mode);
    } finally {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    }
  }

  void _setPermissionMode(String filePath, int? mode) {
    if (mode == null || Platform.isWindows) return;
    final result = Process.runSync('chmod', [mode.toRadixString(8), filePath]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Could not restore file permissions: ${result.stderr}',
        filePath,
      );
    }
  }

  void _cleanupRecovery(DmcPaths paths, String operationId) {
    final anchor = _recoveryFile(paths, operationId, 'anchor');
    final directory = anchor.parent;
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }

  void _verifyFinalState(
    DmcPaths paths,
    List<CheckpointOperationFileRecord> files, {
    required bool intended,
  }) {
    for (final file in files) {
      final state = readWorkspaceState(paths, file.filePath);
      final matches = intended
          ? state.matches(
              file.intendedKind,
              file.intendedHash,
              file.intendedMode,
            )
          : state.matches(file.preKind, file.preHash, file.preMode);
      if (!matches) {
        throw FileSystemException(
          'Workspace changed before final operation verification',
          file.filePath,
        );
      }
    }
  }

  CommandResult _planResult(
    String command,
    CheckpointPlan plan, {
    required bool applied,
    required String mode,
    bool noOp = false,
  }) {
    final issues = plan.checkpointError == null
        ? [...plan.dataErrors, ...plan.conflicts]
        : [plan.checkpointError!];
    return CommandResult(
      command: command,
      exitCode: plan.exitCode,
      data: {
        ...plan.toJson(),
        'mode': mode,
        'applied': applied,
        'operationId': null,
        if (noOp) 'noOp': true,
      },
      errors: [
        for (final issue in issues)
          MachineMessage(issue.code, issue.message, path: issue.path),
      ],
    );
  }

  CommandResult _singleIssueResult(
    String command,
    int exitCode,
    String code,
    String message, {
    String? path,
  }) => CommandResult(
    command: command,
    exitCode: exitCode,
    data: const {'applied': false, 'operationId': null},
    errors: [MachineMessage(code, message, path: path)],
  );
}

List<String> checkpointOperationHumanLines(CommandResult result) {
  final lines = <String>[];
  final data = result.data;
  final direction = data['direction'];
  final mode = data['mode'];
  if (direction != null) {
    lines.add('[DMC] Checkpoint $direction ${mode ?? 'preview'}');
  } else {
    lines.add('[DMC] Checkpoint recovery ${mode ?? ''}'.trimRight());
  }
  final actions = data['actions'];
  if (actions is List) lines.add('Files: ${actions.length}');
  final skipped = data['skipped'];
  if (skipped is List && skipped.isNotEmpty) {
    lines.add(
      'Skipped (protection changed during the checkpoint; never written): ${skipped.length}',
    );
    for (final item in skipped.whereType<Map>()) {
      lines.add('  ${item['code']}: ${item['path']}');
    }
  }
  final operationId = data['operationId'];
  if (operationId != null) lines.add('Operation: $operationId');
  for (final warning in result.warnings) {
    lines.add('Warning: ${warning.message}');
  }
  for (final error in result.errors) {
    lines.add(
      'Error${error.path == null ? '' : ' (${error.path})'}: ${error.message}',
    );
  }
  if (result.ok && mode == 'preview') {
    lines.add('Preview only. Re-run with --apply to change the workspace.');
  }
  if (data['preview'] == true) {
    lines.add(
      'Preview only. Re-run without --preview to recover; execution rechecks conflicts.',
    );
  }
  if (result.exitCode == 6 && operationId != null) {
    lines.add(
      'Recover with: dmc checkpoint recover $operationId --resume or --rollback',
    );
  }
  return lines;
}
