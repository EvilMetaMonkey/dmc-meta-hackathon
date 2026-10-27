import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'checkpoint_models.dart';
import 'checkpoint_operation_models.dart';
import 'checkpoint_operation_repository.dart';
import 'checkpoint_repository.dart';
import 'database.dart';
import 'snapshot_store.dart';
import 'workspace.dart';

class WorkspaceFileState {
  final CheckpointFileKind kind;
  final String? hash;
  final int? mode;

  const WorkspaceFileState(this.kind, this.hash, this.mode);

  bool matches(
    CheckpointFileKind otherKind,
    String? otherHash,
    int? otherMode,
  ) =>
      kind == otherKind &&
      (kind == CheckpointFileKind.absent ||
          (hash == otherHash && (otherMode == null || mode == otherMode)));

  bool matchesContent(CheckpointFileKind otherKind, String? otherHash) =>
      kind == otherKind &&
      (kind == CheckpointFileKind.absent || hash == otherHash);

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'hash': hash,
    'mode': mode,
  };
}

class CheckpointPlanIssue {
  final String code;
  final String message;
  final String? path;

  const CheckpointPlanIssue(this.code, this.message, {this.path});

  Map<String, Object?> toJson() => {
    'code': code,
    'message': message,
    if (path != null) 'path': path,
  };
}

class CheckpointPlanAction {
  final int sequence;
  final String filePath;
  final CheckpointFileKind expectedKind;
  final String? expectedHash;
  final int? expectedMode;
  final CheckpointFileKind intendedKind;
  final int? intendedSnapshotId;
  final String? intendedHash;
  final int? intendedMode;

  const CheckpointPlanAction({
    required this.sequence,
    required this.filePath,
    required this.expectedKind,
    required this.expectedHash,
    required this.expectedMode,
    required this.intendedKind,
    required this.intendedSnapshotId,
    required this.intendedHash,
    required this.intendedMode,
  });

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'path': filePath,
    'expected': {
      'kind': expectedKind.name,
      'hash': expectedHash,
      'mode': expectedMode,
    },
    'intended': {
      'kind': intendedKind.name,
      'snapshotId': intendedSnapshotId,
      'hash': intendedHash,
      'mode': intendedMode,
    },
  };
}

class CheckpointPlan {
  final String checkpointId;
  final CheckpointOperationDirection direction;
  final List<CheckpointPlanAction> actions;
  final List<CheckpointPlanIssue> conflicts;
  final List<CheckpointPlanIssue> dataErrors;
  final CheckpointPlanIssue? checkpointError;

  const CheckpointPlan({
    required this.checkpointId,
    required this.direction,
    this.actions = const [],
    this.conflicts = const [],
    this.dataErrors = const [],
    this.checkpointError,
  });

  bool get canApply =>
      checkpointError == null && conflicts.isEmpty && dataErrors.isEmpty;

  int get exitCode {
    if (checkpointError != null) return 3;
    if (dataErrors.isNotEmpty) return 5;
    if (conflicts.isNotEmpty) return 4;
    return 0;
  }

  Map<String, Object?> toJson() => {
    'checkpointId': checkpointId,
    'direction': direction.name,
    'mode': 'preview',
    'canApply': canApply,
    'actions': actions.map((action) => action.toJson()).toList(),
    'conflicts': conflicts.map((issue) => issue.toJson()).toList(),
    'dataErrors': dataErrors.map((issue) => issue.toJson()).toList(),
  };
}

/// Builds a complete restore/redo plan without writing the workspace, vault, or
/// database. The caller may persist a journal only after this preflight passes.
class CheckpointPlanner {
  final DmcPaths paths;
  final DmcDatabase database;
  final CheckpointRepository checkpoints;
  final CheckpointOperationRepository operations;

  /// Checkpoint paths that Git ignores right now (Git mode only). Restore
  /// and redo never create, overwrite or delete a Git-ignored file.
  final Set<String> gitIgnored;

  const CheckpointPlanner({
    required this.paths,
    required this.database,
    required this.checkpoints,
    required this.operations,
    this.gitIgnored = const {},
  });

  CheckpointPlan build(
    String checkpointId,
    CheckpointOperationDirection direction,
  ) {
    final checkpoint = checkpoints.getCheckpoint(checkpointId);
    if (checkpoint == null) {
      return CheckpointPlan(
        checkpointId: checkpointId,
        direction: direction,
        checkpointError: const CheckpointPlanIssue(
          'checkpoint_not_found',
          'Checkpoint was not found.',
        ),
      );
    }
    if (checkpoint.status != CheckpointStatus.closed) {
      return CheckpointPlan(
        checkpointId: checkpointId,
        direction: direction,
        checkpointError: CheckpointPlanIssue(
          'checkpoint_not_restorable',
          'Checkpoint $checkpointId is ${checkpoint.status.name}; only a closed checkpoint can be applied.',
        ),
      );
    }
    if (direction == CheckpointOperationDirection.redo &&
        operations.latestCompletedRestore(checkpointId) == null) {
      return CheckpointPlan(
        checkpointId: checkpointId,
        direction: direction,
        checkpointError: const CheckpointPlanIssue(
          'redo_unavailable',
          'Redo requires a completed restore for this checkpoint.',
        ),
      );
    }

    final actions = <CheckpointPlanAction>[];
    final conflicts = <CheckpointPlanIssue>[];
    final dataErrors = <CheckpointPlanIssue>[];
    var sequence = 0;
    for (final file in checkpoints.getFiles(checkpointId)) {
      if (file.changeKind == null ||
          file.changeKind == CheckpointChangeKind.unchanged ||
          file.afterKind == null) {
        continue;
      }
      final expectedKind = direction == CheckpointOperationDirection.restore
          ? file.afterKind!
          : file.beforeKind;
      final expectedHash = direction == CheckpointOperationDirection.restore
          ? file.afterHash
          : file.beforeHash;
      final expectedMode = direction == CheckpointOperationDirection.restore
          ? file.afterMode
          : file.beforeMode;
      final intendedKind = direction == CheckpointOperationDirection.restore
          ? file.beforeKind
          : file.afterKind!;
      final intendedSnapshotId =
          direction == CheckpointOperationDirection.restore
          ? file.beforeSnapshotId
          : file.afterSnapshotId;
      final intendedHash = direction == CheckpointOperationDirection.restore
          ? file.beforeHash
          : file.afterHash;
      final intendedMode = direction == CheckpointOperationDirection.restore
          ? file.beforeMode
          : file.afterMode;

      try {
        paths.resolveFile(file.filePath);
      } catch (error) {
        conflicts.add(
          CheckpointPlanIssue(
            'unsafe_path',
            error.toString(),
            path: file.filePath,
          ),
        );
        continue;
      }
      if (gitIgnored.contains(file.filePath)) {
        conflicts.add(
          CheckpointPlanIssue(
            'git_ignored',
            'Git ignores this path now. Restore and redo never create, overwrite or delete a Git-ignored file.',
            path: file.filePath,
          ),
        );
        continue;
      }
      if (intendedKind == CheckpointFileKind.file) {
        final problem = _verifySnapshot(
          file.filePath,
          intendedSnapshotId,
          intendedHash,
        );
        if (problem != null) {
          dataErrors.add(problem);
          continue;
        }
      }
      try {
        final current = readWorkspaceState(paths, file.filePath);
        if (!current.matches(expectedKind, expectedHash, expectedMode)) {
          conflicts.add(
            CheckpointPlanIssue(
              'workspace_drift',
              'Current state does not match the checkpoint ${direction == CheckpointOperationDirection.restore ? 'after' : 'before'} state.',
              path: file.filePath,
            ),
          );
          continue;
        }
      } catch (error) {
        conflicts.add(
          CheckpointPlanIssue(
            'workspace_unavailable',
            error.toString(),
            path: file.filePath,
          ),
        );
        continue;
      }
      actions.add(
        CheckpointPlanAction(
          sequence: sequence++,
          filePath: file.filePath,
          expectedKind: expectedKind,
          expectedHash: expectedHash,
          expectedMode: expectedMode,
          intendedKind: intendedKind,
          intendedSnapshotId: intendedSnapshotId,
          intendedHash: intendedHash,
          intendedMode: intendedMode,
        ),
      );
    }
    return CheckpointPlan(
      checkpointId: checkpointId,
      direction: direction,
      actions: actions,
      conflicts: conflicts,
      dataErrors: dataErrors,
    );
  }

  CheckpointPlanIssue? _verifySnapshot(
    String filePath,
    int? snapshotId,
    String? expectedHash,
  ) {
    if (snapshotId == null || expectedHash == null) {
      return CheckpointPlanIssue(
        'snapshot_reference_missing',
        'The intended file state has no snapshot reference.',
        path: filePath,
      );
    }
    final row = database.getSnapshotById(snapshotId);
    if (row == null ||
        row.filePath != filePath ||
        row.hash != expectedHash ||
        isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath)) {
      return CheckpointPlanIssue(
        'snapshot_reference_invalid',
        'Snapshot $snapshotId does not match the checkpoint manifest.',
        path: filePath,
      );
    }
    try {
      SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        row.snapshotPath,
        row.hash,
      );
    } catch (error) {
      return CheckpointPlanIssue(
        'snapshot_unavailable',
        error.toString(),
        path: filePath,
      );
    }
    return null;
  }
}

WorkspaceFileState readWorkspaceState(DmcPaths paths, String relativePath) {
  final target = validateWorkspaceFileTarget(paths, relativePath);
  final type = FileSystemEntity.typeSync(
    target.absolutePath,
    followLinks: false,
  );
  if (type == FileSystemEntityType.notFound) {
    return const WorkspaceFileState(CheckpointFileKind.absent, null, null);
  }
  if (type != FileSystemEntityType.file) {
    throw FileSystemException(
      'Checkpoint targets must be regular files or absent',
      target.absolutePath,
    );
  }
  final file = File(target.absolutePath);
  final before = file.statSync();
  paths.resolveFile(relativePath);
  final bytes = file.readAsBytesSync();
  paths.resolveFile(relativePath);
  final after = file.statSync();
  if (before.type != FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      bytes.length != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed) {
    throw FileSystemException(
      'File changed during preflight; stop writers and retry',
      target.absolutePath,
    );
  }
  return WorkspaceFileState(
    CheckpointFileKind.file,
    sha256.convert(bytes).toString(),
    checkpointPermissionMode(after),
  );
}

ResolvedFileTarget validateWorkspaceFileTarget(
  DmcPaths paths,
  String relativePath,
) {
  final target = paths.resolveFile(relativePath);
  final parts = p.split(target.relativePath);
  var current = paths.rootPath;
  for (final part in parts.take(parts.length - 1)) {
    current = p.join(current, part);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.notFound) break;
    if (type != FileSystemEntityType.directory) {
      throw FileSystemException(
        'A checkpoint target parent is not a directory',
        current,
      );
    }
  }
  return target;
}

int? checkpointPermissionMode(FileStat stat) =>
    Platform.isWindows ? null : stat.mode & 0x1ff;
