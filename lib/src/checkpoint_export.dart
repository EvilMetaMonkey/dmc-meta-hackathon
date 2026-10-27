import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'checkpoint_models.dart';
import 'checkpoint_repository.dart';
import 'database.dart';
import 'machine_output.dart';
import 'snapshot_store.dart';
import 'workspace.dart';
import 'workspace_operation_lock.dart';

/// Which manifest of a checkpoint to export.
enum CheckpointExportState { before, after }

class _ExportEntry {
  final String relativePath;
  final String snapshotPath;
  final String hash;
  final int? mode;

  const _ExportEntry(
    this.relativePath,
    this.snapshotPath,
    this.hash,
    this.mode,
  );
}

/// `dmc checkpoint export <id> --to <dir> [--state before|after]`: write the
/// files of one checkpoint manifest to a directory outside the workspace,
/// read from the snapshot store with every SHA-256 verified.
///
/// The export holds only files DMC protects; ignored dependencies and build
/// output are not included. It never writes inside the workspace, so it is
/// not a restore and needs no journal. Files are written to a temporary
/// sibling of the target and renamed into place at the end, so a failed
/// export leaves nothing behind.
Future<CommandResult> exportCheckpoint(
  String checkpointId, {
  required String? to,
  String state = 'after',
  String? basePath,
}) async {
  const command = 'checkpoint.export';
  final exportState = CheckpointExportState.values
      .where((value) => value.name == state)
      .firstOrNull;
  if (exportState == null) {
    return machineFailure(
      command,
      2,
      'invalid_state',
      'Export state must be before or after.',
    );
  }
  if (to == null || to.trim().isEmpty) {
    return machineFailure(
      command,
      2,
      'export_target_required',
      'Specify the export directory with --to.',
    );
  }
  final paths = DmcPaths(basePath: basePath);
  if (!File(paths.dbPath).existsSync()) {
    return machineFailure(
      command,
      1,
      'not_initialized',
      'DMC is not initialized.',
    );
  }

  final target = p.normalize(p.absolute(to));
  final targetProblem = _checkTarget(paths.rootPath, target);
  if (targetProblem != null) return targetProblem;

  // Read the manifest under the workspace lock, then release it so a running
  // agent turn is not blocked while the files are copied.
  final List<_ExportEntry> entries;
  final database = DmcDatabase(paths.dbPath);
  WorkspaceOperationLock? lock;
  try {
    lock = WorkspaceOperationLock.acquire(paths);
    database.initialize();
    final repository = CheckpointRepository(database);
    final checkpoint = repository.getCheckpoint(checkpointId);
    if (checkpoint == null) {
      return machineFailure(
        command,
        3,
        'checkpoint_not_found',
        'Checkpoint $checkpointId was not found.',
      );
    }
    final exportable = exportState == CheckpointExportState.after
        ? checkpoint.status == CheckpointStatus.closed
        : const {
            CheckpointStatus.open,
            CheckpointStatus.closing,
            CheckpointStatus.closed,
          }.contains(checkpoint.status);
    if (!exportable) {
      return machineFailure(
        command,
        3,
        'checkpoint_not_exportable',
        exportState == CheckpointExportState.after
            ? 'Checkpoint $checkpointId is ${checkpoint.status.name}; the after state needs a closed checkpoint.'
            : 'Checkpoint $checkpointId is ${checkpoint.status.name}; its before manifest is not available.',
      );
    }
    final collected = <_ExportEntry>[];
    for (final file in repository.getFiles(checkpointId)) {
      final before = exportState == CheckpointExportState.before;
      final kind = before ? file.beforeKind : file.afterKind;
      if (kind != CheckpointFileKind.file) continue;
      final snapshotId = before ? file.beforeSnapshotId : file.afterSnapshotId;
      final hash = before ? file.beforeHash : file.afterHash;
      final row = snapshotId == null
          ? null
          : database.getSnapshotById(snapshotId);
      if (row == null ||
          hash == null ||
          row.hash != hash ||
          isTombstoneSnapshot(hash: row.hash, snapshotPath: row.snapshotPath)) {
        return machineFailure(
          command,
          5,
          'snapshot_reference_invalid',
          'The ${exportState.name} state of ${file.filePath} has no valid snapshot.',
          path: file.filePath,
        );
      }
      collected.add(
        _ExportEntry(
          file.filePath,
          row.snapshotPath,
          hash,
          before ? file.beforeMode : file.afterMode,
        ),
      );
    }
    entries = collected;
  } on WorkspaceOperationBusy {
    return machineFailure(
      command,
      3,
      'checkpoint_busy',
      'Another checkpoint command is running in this workspace.',
    );
  } catch (error) {
    return machineFailure(command, 1, 'export_failed', error.toString());
  } finally {
    database.close();
    lock?.close();
  }

  final parent = p.dirname(target);
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  final staging = Directory(
    p.join(parent, '.${p.basename(target)}.dmc-export-$suffix'),
  );
  try {
    staging.createSync();
    var totalBytes = 0;
    final byMode = <int, List<String>>{};
    for (final entry in entries) {
      final destination = _destination(staging.path, entry.relativePath);
      final bytes = SnapshotStore.readVerifiedBytes(
        paths.snapshotsPath,
        entry.snapshotPath,
        entry.hash,
      );
      _createDirectories(staging.path, p.dirname(destination));
      if (FileSystemEntity.typeSync(destination, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException('Export path already exists', destination);
      }
      File(destination).writeAsBytesSync(bytes, flush: true);
      totalBytes += bytes.length;
      if (entry.mode != null) {
        (byMode[entry.mode!] ??= []).add(destination);
      }
    }
    if (!Platform.isWindows) {
      for (final group in byMode.entries) {
        for (var start = 0; start < group.value.length; start += 200) {
          final batch = group.value.sublist(
            start,
            min(start + 200, group.value.length),
          );
          final result = Process.runSync('chmod', [
            group.key.toRadixString(8),
            ...batch,
          ]);
          if (result.exitCode != 0) {
            throw FileSystemException(
              'Could not set file permissions: ${result.stderr}',
              batch.first,
            );
          }
        }
      }
    }
    if (Platform.isWindows &&
        FileSystemEntity.typeSync(target, followLinks: false) ==
            FileSystemEntityType.directory) {
      // Windows cannot rename onto an existing directory; it was checked to
      // be empty. POSIX rename replaces an empty directory atomically.
      Directory(target).deleteSync();
    }
    staging.renameSync(target);
    return CommandResult(
      command: command,
      exitCode: 0,
      data: {
        'checkpointId': checkpointId,
        'state': exportState.name,
        'directory': target,
        'fileCount': entries.length,
        'totalBytes': totalBytes,
        'manifestSha256': exportManifestSha256([
          for (final entry in entries)
            (path: entry.relativePath, hash: entry.hash, mode: entry.mode),
        ]),
      },
    );
  } catch (error) {
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    } catch (_) {
      // Best effort; the failure below is what matters.
    }
    final integrity = error is SnapshotIntegrityException;
    return machineFailure(
      command,
      integrity ? 5 : 1,
      integrity ? 'snapshot_unavailable' : 'export_failed',
      '$error Nothing was exported.',
    );
  }
}

/// SHA-256 of the exported manifest: one `<mode>\t<sha256>\t<path>\n` line
/// per file, sorted by POSIX path, with the mode in octal (`-` when none was
/// recorded). Two exports with the same hash hold the same bytes and modes.
String exportManifestSha256(
  Iterable<({String path, String hash, int? mode})> entries,
) {
  final lines = [
    for (final entry in entries)
      (path: p.split(entry.path).join('/'), hash: entry.hash, mode: entry.mode),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final text = lines
      .map(
        (line) =>
            '${line.mode?.toRadixString(8) ?? '-'}\t${line.hash}\t${line.path}\n',
      )
      .join();
  return sha256.convert(utf8.encode(text)).toString();
}

CommandResult? _checkTarget(String root, String target) {
  const command = 'checkpoint.export';
  CommandResult unsafe(String message) =>
      machineFailure(command, 2, 'unsafe_export_target', message);
  final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
  final canonicalTarget = _canonical(target);
  for (final (rootForm, targetForm) in [
    (root, target),
    (canonicalRoot, canonicalTarget),
  ]) {
    if (p.equals(rootForm, targetForm) || p.isWithin(rootForm, targetForm)) {
      return unsafe(
        'The export directory $target is inside the workspace. Export outside it.',
      );
    }
    if (p.isWithin(targetForm, rootForm)) {
      return unsafe(
        'The workspace is inside the export directory $target. Export elsewhere.',
      );
    }
  }
  final parent = p.dirname(target);
  if (FileSystemEntity.typeSync(parent) != FileSystemEntityType.directory) {
    return machineFailure(
      command,
      2,
      'export_parent_missing',
      'The parent directory of $target does not exist.',
    );
  }
  switch (FileSystemEntity.typeSync(target, followLinks: false)) {
    case FileSystemEntityType.notFound:
      return null;
    case FileSystemEntityType.directory:
      if (Directory(target).listSync(followLinks: false).isEmpty) return null;
      return machineFailure(
        command,
        4,
        'export_target_not_empty',
        'The export directory $target is not empty.',
      );
    default:
      return machineFailure(
        command,
        4,
        'export_target_not_directory',
        '$target exists and is not a directory (links are never followed).',
      );
  }
}

/// [path] with its nearest existing ancestor's links resolved.
String _canonical(String path) {
  var existing = path;
  final rest = <String>[];
  while (FileSystemEntity.typeSync(existing) == FileSystemEntityType.notFound) {
    final parent = p.dirname(existing);
    if (parent == existing) return path;
    rest.insert(0, p.basename(existing));
    existing = parent;
  }
  try {
    return p.joinAll([Directory(existing).resolveSymbolicLinksSync(), ...rest]);
  } on FileSystemException {
    return path;
  }
}

String _destination(String staging, String relativePath) {
  final parts = p.split(relativePath);
  if (p.isAbsolute(relativePath) ||
      parts.isEmpty ||
      parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FileSystemException('Unsafe manifest path', relativePath);
  }
  return p.joinAll([staging, ...parts]);
}

/// Create [directory] below [staging] one component at a time, refusing any
/// component that exists as something other than a real directory.
void _createDirectories(String staging, String directory) {
  var current = staging;
  for (final part in p.split(p.relative(directory, from: staging))) {
    if (part == '.') continue;
    current = p.join(current, part);
    switch (FileSystemEntity.typeSync(current, followLinks: false)) {
      case FileSystemEntityType.notFound:
        Directory(current).createSync();
      case FileSystemEntityType.directory:
        break;
      default:
        throw FileSystemException('Export path is not a directory', current);
    }
  }
}

List<String> checkpointExportHumanLines(CommandResult result) {
  final data = result.data;
  return [
    if (result.ok) ...[
      '[DMC] Exported checkpoint ${data['checkpointId']} (${data['state']} state) to ${data['directory']}',
      'Files: ${data['fileCount']}; bytes: ${data['totalBytes']}',
      'Manifest SHA-256: ${data['manifestSha256']}',
      'Only files DMC protects are exported. Ignored dependencies and build output are not included.',
    ],
    for (final error in result.errors)
      '[DMC] Error${error.path == null ? '' : ' ${error.path}'}: ${error.message}',
  ];
}
