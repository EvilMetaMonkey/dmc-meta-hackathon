import 'dart:io';
import 'package:path/path.dart' as p;
import 'git_ignore.dart';
import 'ignore.dart';
import 'workspace.dart';

class WorkspaceScan {
  final List<String> files = [];
  final List<String> directories = [];
  final Map<String, String> exclusions = {};
  final Map<String, String> errors = {};

  /// Git's view of the workspace, in Git mode only.
  GitFileListing? gitListing;
}

/// Exclusion reason for submodules and nested repositories in Git mode.
const String nestedRepositoryExclusion = 'nested repository';

/// The scan error prefix used when Git cannot list the workspace.
const String gitScanErrorPrefix = 'Git could not list the workspace';

/// Scan the files [policy] keeps in scope. Every DMC path that needs the
/// protected file list (checkpoint begin, close and verification, manual
/// snapshots and the watcher) goes through here.
Future<WorkspaceScan> scanWorkspacePolicy(
  DmcPaths paths,
  IgnorePolicy policy, {
  void Function(String directory)? onDirectory,
}) => scanWorkspace(
  paths,
  policy.rules,
  git: policy.git,
  onDirectory: onDirectory,
);

/// Walk one directory at a time, pruning before descent and never following
/// links. Nested .gitignore files are deliberately rejected, not misinterpreted.
///
/// With [git] (Git mode), Git's file list replaces the walk: tracked files
/// plus untracked files Git does not ignore. [rules], link checks and the
/// nested-repository exclusion then apply on top.
Future<WorkspaceScan> scanWorkspace(
  DmcPaths paths,
  List<IgnoreRule> rules, {
  GitWorkTree? git,
  void Function(String directory)? onDirectory,
}) async {
  if (git != null) return _scanWithGit(paths, rules, git, onDirectory);
  final result = WorkspaceScan();
  Future<void> visit(String directory) async {
    try {
      paths.validateInternalPath(directory);
      result.directories.add(directory);
      onDirectory?.call(directory);
      await for (final entity in Directory(
        directory,
      ).list(followLinks: false)) {
        final relative = p.relative(entity.path, from: paths.rootPath);
        final directoryEntry = entity is Directory;
        if (rules.any(
          (rule) => rule.matches(relative, isDirectory: directoryEntry),
        )) {
          result.exclusions[relative] = 'ignored';
          continue;
        }
        if (entity is Link) {
          result.exclusions[relative] = 'symlink';
        } else if (entity is Directory) {
          await visit(entity.path);
        } else if (entity is File) {
          if (p.basename(entity.path) == '.gitignore' &&
              directory != paths.rootPath) {
            result.errors[relative] =
                'Nested .gitignore is not supported. Move protection rules to the root .dmcignore before starting DMC.';
          } else {
            result.files.add(entity.path);
          }
        } else {
          result.exclusions[relative] = 'unsupported file type';
        }
      }
    } catch (e) {
      result.errors[p.relative(directory, from: paths.rootPath)] = e.toString();
    }
  }

  await visit(paths.rootPath);
  return result;
}

Future<WorkspaceScan> _scanWithGit(
  DmcPaths paths,
  List<IgnoreRule> rules,
  GitWorkTree git,
  void Function(String directory)? onDirectory,
) async {
  final result = WorkspaceScan();
  final GitFileListing listing;
  try {
    listing = await git.list();
  } on GitIgnoreException catch (error) {
    result.errors['.'] = '$gitScanErrorPrefix: ${error.message}';
    return result;
  }
  result.gitListing = listing;

  // Report what Git ignores, collapsed to the topmost listed entry.
  final ignored = [
    for (final entry in listing.ignored)
      entry.endsWith(p.separator)
          ? entry.substring(0, entry.length - p.separator.length)
          : entry,
  ]..sort();
  final reported = <String>[];
  for (final entry in ignored) {
    if (reported.any((parent) => p.isWithin(parent, entry))) continue;
    reported.add(entry);
    result.exclusions[entry] = 'ignored';
  }

  final directories = <String>{paths.rootPath};
  // Directory (relative) → null when it is a real directory inside the
  // workspace, or the relative path of the link/non-directory that blocks it.
  final blocked = <String, String?>{};
  String? blockerFor(String relativeDirectory) {
    if (relativeDirectory == '.' || relativeDirectory.isEmpty) return null;
    if (blocked.containsKey(relativeDirectory)) {
      return blocked[relativeDirectory];
    }
    final parentBlocker = blockerFor(p.dirname(relativeDirectory));
    final String? blocker;
    if (parentBlocker != null) {
      blocker = parentBlocker;
    } else {
      final type = FileSystemEntity.typeSync(
        p.join(paths.rootPath, relativeDirectory),
        followLinks: false,
      );
      blocker = type == FileSystemEntityType.directory
          ? null
          : relativeDirectory;
    }
    return blocked[relativeDirectory] = blocker;
  }

  bool dmcIgnored(String relative, {required bool isDirectory}) {
    final segments = p.split(relative);
    for (var length = 1; length <= segments.length; length++) {
      final prefix = p.joinAll(segments.take(length));
      final prefixIsDirectory = length < segments.length || isDirectory;
      if (rules.any(
        (rule) => rule.matches(prefix, isDirectory: prefixIsDirectory),
      )) {
        result.exclusions[prefix] = 'ignored';
        return true;
      }
    }
    return false;
  }

  for (final entry in listing.included.toList()..sort()) {
    if (entry.endsWith(p.separator)) {
      final relative = entry.substring(0, entry.length - p.separator.length);
      if (!dmcIgnored(relative, isDirectory: true)) {
        result.exclusions[relative] = nestedRepositoryExclusion;
      }
      continue;
    }
    final relative = p.normalize(entry);
    if (relative == '.' || relative.startsWith('..')) continue;
    if (dmcIgnored(relative, isDirectory: false)) continue;
    final blocker = blockerFor(p.dirname(relative));
    if (blocker != null) {
      final absolute = p.join(paths.rootPath, blocker);
      final type = FileSystemEntity.typeSync(absolute, followLinks: false);
      if (type == FileSystemEntityType.link) {
        result.exclusions[blocker] = 'symlink';
      }
      // A missing parent means the tracked file was deleted: not in scope.
      continue;
    }
    final absolute = p.join(paths.rootPath, relative);
    switch (FileSystemEntity.typeSync(absolute, followLinks: false)) {
      case FileSystemEntityType.file:
        result.files.add(absolute);
        var directory = p.dirname(absolute);
        while (directories.add(directory)) {
          directory = p.dirname(directory);
        }
      case FileSystemEntityType.link:
        result.exclusions[relative] = 'symlink';
      case FileSystemEntityType.directory:
        // A gitlink: a submodule or an embedded repository.
        result.exclusions[relative] = nestedRepositoryExclusion;
      case FileSystemEntityType.notFound:
        // Tracked but deleted from the work tree.
        break;
      default:
        result.exclusions[relative] = 'unsupported file type';
    }
  }

  try {
    paths.validateInternalPath(paths.rootPath);
  } catch (e) {
    result.errors['.'] = e.toString();
  }
  result.directories.addAll(directories.toList()..sort());
  if (onDirectory != null) {
    for (final directory in result.directories) {
      onDirectory(directory);
    }
  }
  return result;
}
