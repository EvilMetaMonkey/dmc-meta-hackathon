import 'dart:io';

import 'package:path/path.dart' as p;

import 'git_ignore.dart';
import 'workspace.dart';

/// How a workspace sits among Git worktrees, read from `.git` markers and
/// Git's metadata files only (no git process).
class GitWorktreeInfo {
  /// The work tree that contains the workspace root.
  final String workTree;

  /// True when [workTree] is a linked worktree: its `.git` is a file that
  /// points into the main repository's `worktrees/` directory.
  final bool linked;

  /// The main work tree, when it can be read from the metadata.
  final String? mainWorkTree;

  /// For the main work tree: its linked worktrees and whether each has a dmc
  /// vault. Empty for a linked worktree.
  final List<({String path, bool hasVault})> linkedWorktrees;

  const GitWorktreeInfo({
    required this.workTree,
    required this.linked,
    this.mainWorkTree,
    this.linkedWorktrees = const [],
  });

  /// The lines `status` and `doctor` print.
  List<String> get lines => linked
      ? [
          'Git worktree: linked worktree of ${mainWorkTree ?? 'an unknown main work tree'}',
          'Worktree vault: this worktree has its own dmc vault and checkpoints, separate from the main work tree.',
        ]
      : [
          'Git worktree: main work tree, ${linkedWorktrees.length} linked worktree(s)',
          for (final worktree in linkedWorktrees)
            'Linked worktree: ${worktree.path} (${worktree.hasVault ? 'own dmc vault' : 'no dmc vault; run "dmc init" there to protect it'})',
        ];
}

/// Describe the Git worktree that contains [root], or null outside Git.
GitWorktreeInfo? describeGitWorktree(String root) {
  final marker = findGitMarker(root);
  if (marker == null) return null;
  final workTree = p.dirname(marker);
  if (FileSystemEntity.typeSync(marker, followLinks: false) ==
      FileSystemEntityType.file) {
    final gitDir = _readGitDir(marker);
    if (gitDir == null || p.basename(p.dirname(gitDir)) != 'worktrees') {
      // A submodule or a separate git dir: not a linked worktree.
      return GitWorktreeInfo(workTree: workTree, linked: false);
    }
    String? main;
    final commonDir = _readLine(p.join(gitDir, 'commondir'));
    if (commonDir != null) {
      final common = p.normalize(
        p.isAbsolute(commonDir) ? commonDir : p.join(gitDir, commonDir),
      );
      if (p.basename(common) == '.git') main = p.dirname(common);
    }
    return GitWorktreeInfo(
      workTree: workTree,
      linked: true,
      mainWorkTree: main,
    );
  }
  final worktrees = <({String path, bool hasVault})>[];
  final metadata = Directory(p.join(marker, 'worktrees'));
  if (metadata.existsSync()) {
    for (final entry
        in metadata.listSync(followLinks: false).whereType<Directory>()) {
      final pointer = _readLine(p.join(entry.path, 'gitdir'));
      if (pointer == null) continue;
      final path = p.dirname(p.normalize(pointer));
      worktrees.add((
        path: path,
        hasVault:
            FileSystemEntity.typeSync(
              p.join(path, dmcDirName),
              followLinks: false,
            ) ==
            FileSystemEntityType.directory,
      ));
    }
    worktrees.sort((a, b) => a.path.compareTo(b.path));
  }
  return GitWorktreeInfo(
    workTree: workTree,
    linked: false,
    linkedWorktrees: worktrees,
  );
}

String? _readGitDir(String markerFile) {
  final line = _readLine(markerFile);
  if (line == null || !line.startsWith('gitdir:')) return null;
  final value = line.substring('gitdir:'.length).trim();
  return p.normalize(
    p.isAbsolute(value) ? value : p.join(p.dirname(markerFile), value),
  );
}

String? _readLine(String path) {
  try {
    final text = File(path).readAsStringSync().trim();
    return text.isEmpty ? null : text.split(RegExp(r'\r?\n')).first.trim();
  } on FileSystemException {
    return null;
  }
}
