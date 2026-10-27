import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Git-mode ignore handling. When the workspace root is inside a Git work
/// tree, Git decides what is ignored; DMC never re-implements Git's rules.
///
/// Git is required in that mode. If it cannot be found or run, callers fail
/// with [GitIgnoreException] instead of silently falling back to DMC's own
/// subset parser.

/// Finds a Git executable, or returns null.
typedef GitLocator = String? Function();

/// Raised when the workspace is a Git work tree but Git cannot decide what is
/// ignored. [code] is a stable machine code.
class GitIgnoreException implements Exception {
  final String code;
  final String message;

  const GitIgnoreException(this.code, this.message);

  @override
  String toString() => message;
}

/// Environment variables that would point Git at a different repository,
/// index or work tree than the one DMC detected.
const List<String> _strippedGitEnvironment = [
  'GIT_DIR',
  'GIT_WORK_TREE',
  'GIT_INDEX_FILE',
  'GIT_COMMON_DIR',
  'GIT_OBJECT_DIRECTORY',
  'GIT_NAMESPACE',
  'GIT_CEILING_DIRECTORIES',
  'GIT_DISCOVERY_ACROSS_FILESYSTEM',
];

/// Look for `git` on PATH, then in the usual install locations.
String? locateGit({Map<String, String>? environment}) {
  final env = environment ?? Platform.environment;
  final names = Platform.isWindows ? const ['git.exe'] : const ['git'];
  final pathValue = env['PATH'] ?? env['Path'] ?? '';
  for (final directory in pathValue.split(Platform.isWindows ? ';' : ':')) {
    if (directory.trim().isEmpty) continue;
    for (final name in names) {
      final candidate = p.join(directory.trim(), name);
      if (_isExecutableFile(candidate)) return candidate;
    }
  }
  final fallbacks = Platform.isWindows
      ? [
          for (final base in [
            env['ProgramFiles'],
            env['ProgramW6432'],
            r'C:\Program Files',
          ])
            if (base != null) p.join(base, 'Git', 'cmd', 'git.exe'),
          if (env['LOCALAPPDATA'] != null)
            p.join(env['LOCALAPPDATA']!, 'Programs', 'Git', 'cmd', 'git.exe'),
        ]
      : const ['/usr/bin/git', '/opt/homebrew/bin/git', '/usr/local/bin/git'];
  for (final candidate in fallbacks) {
    if (_isExecutableFile(candidate)) return candidate;
  }
  return null;
}

bool _isExecutableFile(String path) {
  try {
    final stat = FileStat.statSync(path);
    if (stat.type != FileSystemEntityType.file) return false;
    return Platform.isWindows || stat.mode & 0x49 != 0;
  } on FileSystemException {
    return false;
  }
}

/// The nearest `.git` directory or file at or above [root], or null when the
/// root is not inside a Git work tree.
String? findGitMarker(String root) {
  var current = p.normalize(p.absolute(root));
  while (true) {
    final marker = p.join(current, '.git');
    final type = FileSystemEntity.typeSync(marker, followLinks: false);
    if (type == FileSystemEntityType.directory ||
        type == FileSystemEntityType.file) {
      return marker;
    }
    final parent = p.dirname(current);
    if (parent == current) return null;
    current = parent;
  }
}

/// One `git ls-files` view of the workspace, as native relative paths.
class GitFileListing {
  /// Tracked files plus untracked files Git does not ignore. Entries that end
  /// in a separator are untracked nested repositories.
  final List<String> included;

  /// Untracked paths Git ignores. Directory entries end in a separator.
  final List<String> ignored;

  const GitFileListing(this.included, this.ignored);
}

/// A workspace root inside a Git work tree, with the Git executable to ask.
class GitWorkTree {
  final String executable;
  final String root;
  final String topLevel;
  final Map<String, String> _environment;

  GitWorkTree._(this.executable, this.root, this.topLevel, this._environment);

  /// Detect Git mode for [root]. Returns null outside a Git work tree, and
  /// throws [GitIgnoreException] when the root is inside one but Git cannot
  /// be run.
  static Future<GitWorkTree?> detect(
    String root, {
    GitLocator? locator,
    Map<String, String>? environment,
  }) async {
    final normalizedRoot = p.normalize(p.absolute(root));
    final marker = findGitMarker(normalizedRoot);
    if (marker == null) return null;
    final executable = (locator ?? () => locateGit(environment: environment))();
    if (executable == null) {
      throw GitIgnoreException(
        'git_unavailable',
        'This workspace is inside a Git work tree (${p.dirname(marker)}), so Git decides what is ignored, but git was not found on PATH or in ${Platform.isWindows ? r'C:\Program Files\Git\cmd' : '/usr/bin, /opt/homebrew/bin or /usr/local/bin'}. Install Git or add it to PATH; DMC will not guess Git ignore rules.',
      );
    }
    final env = {
      for (final entry in (environment ?? Platform.environment).entries)
        if (!_strippedGitEnvironment.contains(entry.key))
          entry.key: entry.value,
      'GIT_OPTIONAL_LOCKS': '0',
      'GIT_TERMINAL_PROMPT': '0',
    };
    final probe = GitWorkTree._(executable, normalizedRoot, '', env);
    final lines = const LineSplitter().convert(
      await probe._runText([
        'rev-parse',
        '--is-inside-work-tree',
        '--show-toplevel',
      ]),
    );
    if (lines.length < 2 || lines[0].trim() != 'true') {
      throw GitIgnoreException(
        'git_failed',
        'Git does not treat $normalizedRoot as part of a work tree, although ${p.dirname(marker)} has a .git entry. Fix the repository or remove the stray .git entry.',
      );
    }
    // Git reports a canonical top level (macOS /private/var for /var, long
    // Windows names). Express it in the same form as the root.
    var topLevel = p.normalize(lines[1].trim());
    try {
      final canonicalRoot = Directory(
        normalizedRoot,
      ).resolveSymbolicLinksSync();
      final upward = p.relative(topLevel, from: canonicalRoot);
      if (upward == '.' || p.split(upward).every((part) => part == '..')) {
        topLevel = p.normalize(p.join(normalizedRoot, upward));
      }
    } catch (_) {
      // Keep Git's form (for example, on another drive).
    }
    return GitWorkTree._(executable, normalizedRoot, topLevel, env);
  }

  Future<ProcessResult> _run(List<String> args, {String? stdinText}) async {
    try {
      if (stdinText == null) {
        return await Process.run(
          executable,
          ['-C', root, ...args],
          environment: _environment,
          includeParentEnvironment: false,
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      }
      final process = await Process.start(
        executable,
        ['-C', root, ...args],
        environment: _environment,
        includeParentEnvironment: false,
      );
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      try {
        process.stdin.add(utf8.encode(stdinText));
        await process.stdin.close();
      } catch (_) {
        // Git exited before reading everything; its exit code says why.
      }
      return ProcessResult(
        process.pid,
        await process.exitCode,
        await stdout,
        await stderr,
      );
    } on ProcessException catch (error) {
      throw GitIgnoreException(
        'git_unavailable',
        'Could not run $executable: ${error.message}',
      );
    }
  }

  Future<String> _runText(
    List<String> args, {
    Set<int> okExitCodes = const {0},
    String? stdinText,
  }) async {
    final result = await _run(args, stdinText: stdinText);
    if (!okExitCodes.contains(result.exitCode)) {
      final detail = (result.stderr as String).trim();
      throw GitIgnoreException(
        'git_failed',
        'git ${args.first} failed (exit ${result.exitCode})${detail.isEmpty ? '' : ': $detail'}',
      );
    }
    return result.stdout as String;
  }

  static List<String> _nulList(String output) => [
    for (final entry in output.split('\x00'))
      if (entry.isNotEmpty) _toNative(entry),
  ];

  static String _toNative(String gitPath) {
    final directory = gitPath.endsWith('/');
    final native = p.joinAll(
      p.posix.split(
        directory ? gitPath.substring(0, gitPath.length - 1) : gitPath,
      ),
    );
    return directory ? '$native${p.separator}' : native;
  }

  static String _toGit(String nativeRelative) =>
      p.split(nativeRelative).join('/');

  /// List the workspace the way Git sees it.
  Future<GitFileListing> list() async {
    final included = await _runText([
      'ls-files',
      '--cached',
      '--others',
      '--exclude-standard',
      '-z',
    ]);
    final ignored = await _runText([
      'ls-files',
      '--others',
      '--ignored',
      '--exclude-standard',
      '--directory',
      '-z',
    ]);
    return GitFileListing(
      _nulList(included).toSet().toList(),
      _nulList(ignored).toSet().toList(),
    );
  }

  /// The subset of [relativePaths] (native, relative to [root]) that Git
  /// ignores. Tracked files are never ignored, as in Git. One process.
  Future<Set<String>> ignoredAmong(Iterable<String> relativePaths) async {
    final byGitPath = {for (final path in relativePaths) _toGit(path): path};
    if (byGitPath.isEmpty) return const {};
    final output = await _runText(
      ['check-ignore', '--stdin', '-z'],
      okExitCodes: const {0, 1},
      stdinText: '${byGitPath.keys.join('\x00')}\x00',
    );
    return {
      for (final entry in output.split('\x00'))
        if (byGitPath[entry] != null) byGitPath[entry]!,
    };
  }

  /// Every ignore source Git reads for this workspace, each with the SHA-256
  /// of its bytes (null when missing): the effective .gitignore files, the
  /// repository's info/exclude and core.excludesFile.
  Future<List<Map<String, Object?>>> ignoreSources(
    GitFileListing listing,
  ) async {
    final gitignores = <String>{};
    // .gitignore files above the workspace root, up to the top level.
    var directory = p.dirname(root);
    while (p.isWithin(topLevel, root) &&
        (p.isWithin(topLevel, directory) || p.equals(topLevel, directory))) {
      gitignores.add(p.join(directory, '.gitignore'));
      if (p.equals(topLevel, directory)) break;
      directory = p.dirname(directory);
    }
    final wholeDirectories = <String>[];
    for (final entry in [...listing.included, ...listing.ignored]) {
      if (entry.endsWith(p.separator)) {
        final directory = entry.substring(0, entry.length - p.separator.length);
        if (File(p.join(root, directory, '.gitignore')).existsSync()) {
          wholeDirectories.add(directory);
        }
      } else if (p.basename(entry) == '.gitignore') {
        gitignores.add(p.join(root, entry));
      }
    }
    // Git lists a directory whole either because a pattern ignores it (Git
    // never reads its .gitignore, as with .pytest_cache/ or a venv) or
    // because its own .gitignore ignores everything in it (Git does).
    if (wholeDirectories.isNotEmpty) {
      final ignoredDirectories = await ignoredAmong(wholeDirectories);
      for (final directory in wholeDirectories) {
        if (!ignoredDirectories.contains(directory)) {
          gitignores.add(p.join(root, directory, '.gitignore'));
        }
      }
    }

    final excludePath = (await _runText([
      'rev-parse',
      '--git-path',
      'info/exclude',
    ])).trim();
    final configured = (await _runText(
      ['config', '--path', '--get', 'core.excludesFile'],
      okExitCodes: const {0, 1},
    )).trim();
    String? excludesFile = configured.isEmpty ? null : configured;
    if (excludesFile == null) {
      final xdg = _environment['XDG_CONFIG_HOME'];
      final home = _environment['HOME'] ?? _environment['USERPROFILE'];
      if (xdg != null && xdg.isNotEmpty) {
        excludesFile = p.join(xdg, 'git', 'ignore');
      } else if (home != null) {
        excludesFile = p.join(home, '.config', 'git', 'ignore');
      }
    }

    String? digest(String path) {
      try {
        final file = File(path);
        if (!file.existsSync()) return null;
        return sha256.convert(file.readAsBytesSync()).toString();
      } on FileSystemException {
        return 'unreadable';
      }
    }

    final sources = <Map<String, Object?>>[];
    for (final path in gitignores.toList()..sort()) {
      final hash = digest(path);
      // A missing .gitignore under a listed directory is not a source.
      if (hash == null) continue;
      sources.add({
        'kind': 'gitignore',
        'path': p.split(p.relative(path, from: topLevel)).join('/'),
        'sha256': hash,
      });
    }
    final exclude = p.normalize(
      p.isAbsolute(excludePath) ? excludePath : p.join(root, excludePath),
    );
    sources.add({
      'kind': 'info/exclude',
      'path': p.split(p.relative(exclude, from: topLevel)).join('/'),
      'sha256': digest(exclude),
    });
    sources.add({
      'kind': 'core.excludesFile',
      'path': excludesFile,
      'sha256': excludesFile == null ? null : digest(excludesFile),
    });
    return sources;
  }
}
