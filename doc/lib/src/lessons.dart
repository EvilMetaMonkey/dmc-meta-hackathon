import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Where a lesson came from: the checkpoint (and agent turn) it was drafted
/// from.
class LessonSource {
  final String checkpoint;
  final String? agent;
  final String? session;

  const LessonSource({required this.checkpoint, this.agent, this.session});
}

/// One lesson: what was tried, why it failed, and what to do instead,
/// tagged with the workspace-relative files it covers.
class Lesson {
  final String id;
  final String title;

  /// Workspace-relative POSIX paths. Taken from the checkpoint manifest,
  /// never from a model.
  final List<String> files;
  final DateTime created;
  final LessonSource source;

  /// `draft` until `doc lesson approve`, then `approved`.
  final String status;
  final String body;

  const Lesson({
    required this.id,
    required this.title,
    required this.files,
    required this.created,
    required this.source,
    required this.status,
    required this.body,
  });

  Lesson withStatus(String value) => Lesson(
    id: id,
    title: title,
    files: files,
    created: created,
    source: source,
    status: value,
    body: body,
  );

  /// Markdown with YAML front matter. Strings are written as JSON strings,
  /// which are valid double-quoted YAML.
  String toMarkdown() {
    String quote(String value) => jsonEncode(value);
    return [
      '---',
      'id: ${quote(id)}',
      'title: ${quote(title)}',
      'files:',
      for (final file in files) '  - ${quote(file)}',
      'created: ${quote(created.toUtc().toIso8601String())}',
      'source:',
      '  checkpoint: ${quote(source.checkpoint)}',
      if (source.agent != null) '  agent: ${quote(source.agent!)}',
      if (source.session != null) '  session: ${quote(source.session!)}',
      'status: ${quote(status)}',
      '---',
      '',
      body.trim(),
      '',
    ].join('\n');
  }

  /// Parse [text] written by [toMarkdown] (or edited by hand in the same
  /// shape). Throws [FormatException] on anything else.
  static Lesson parse(String text) {
    final normalized = text.replaceAll('\r\n', '\n');
    if (!normalized.startsWith('---\n')) {
      throw const FormatException(
        'A lesson must start with "---" front matter.',
      );
    }
    final end = normalized.indexOf('\n---\n', 4);
    if (end < 0) {
      throw const FormatException('The front matter has no closing "---".');
    }
    final header = normalized.substring(4, end).split('\n');
    final body = normalized.substring(end + 5).trim();

    final scalars = <String, String>{};
    final files = <String>[];
    final source = <String, String>{};
    String? section;
    String value(String raw) {
      final trimmed = raw.trim();
      if (trimmed.startsWith('"')) return jsonDecode(trimmed) as String;
      if (trimmed.startsWith("'") &&
          trimmed.endsWith("'") &&
          trimmed.length >= 2) {
        return trimmed.substring(1, trimmed.length - 1).replaceAll("''", "'");
      }
      return trimmed;
    }

    for (final line in header) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final item = RegExp(r'^\s+-\s+(.*)$').firstMatch(line);
      if (item != null) {
        if (section != 'files') {
          throw FormatException('Unexpected list item: $line');
        }
        files.add(value(item[1]!));
        continue;
      }
      final nested = RegExp(r'^\s+([A-Za-z_]+):\s*(.*)$').firstMatch(line);
      if (nested != null) {
        if (section != 'source') {
          throw FormatException('Unexpected nested key: $line');
        }
        source[nested[1]!] = value(nested[2]!);
        continue;
      }
      final top = RegExp(r'^([A-Za-z_]+):\s*(.*)$').firstMatch(line);
      if (top == null) {
        throw FormatException('Cannot read front matter line: $line');
      }
      final key = top[1]!;
      final rest = top[2]!;
      if (rest.trim().isEmpty) {
        section = key;
      } else {
        section = null;
        scalars[key] = value(rest);
      }
    }
    String required(String key) {
      final found = scalars[key];
      if (found == null || found.isEmpty) {
        throw FormatException('The front matter needs "$key".');
      }
      return found;
    }

    final created = DateTime.tryParse(required('created'));
    if (created == null) {
      throw FormatException('"created" is not a date: ${scalars['created']}');
    }
    final checkpoint = source['checkpoint'];
    if (checkpoint == null || checkpoint.isEmpty) {
      throw const FormatException('The front matter needs source.checkpoint.');
    }
    return Lesson(
      id: required('id'),
      title: required('title'),
      files: files,
      created: created.toUtc(),
      source: LessonSource(
        checkpoint: checkpoint,
        agent: source['agent'],
        session: source['session'],
      ),
      status: required('status'),
      body: body,
    );
  }

  /// Problems that block approval, or an empty list.
  List<String> problems() => [
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id))
      'id must be lowercase letters, digits and dashes',
    if (title.trim().isEmpty) 'title is empty',
    if (files.isEmpty) 'files is empty',
    for (final file in files)
      if (!isSafeRelativePath(file))
        'file "$file" is not a workspace-relative path',
    if (body.trim().isEmpty) 'the body is empty',
  ];
}

bool isSafeRelativePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) return false;
  if (RegExp(r'^[A-Za-z]:').hasMatch(path)) return false;
  return !path
      .split('/')
      .any((part) => part.isEmpty || part == '.' || part == '..');
}

/// A workspace-relative path in POSIX form, or null if it cannot be one.
String? normalizeWorkspacePath(String raw) {
  var path = raw.trim().replaceAll('\\', '/');
  while (path.startsWith('./')) {
    path = path.substring(2);
  }
  return isSafeRelativePath(path) ? path : null;
}

/// Doc's data directory: `$DOC_DATA_DIR`, else `%LOCALAPPDATA%\dmc-doc` on
/// Windows, `$XDG_DATA_HOME/dmc-doc`, or `~/.local/share/dmc-doc`. Lessons
/// live here, never in a repository or in `.dmc/`.
String docDataDirectory(Map<String, String> environment) {
  final explicit = environment['DOC_DATA_DIR'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (Platform.isWindows) {
    final local = environment['LOCALAPPDATA'];
    if (local != null) return p.join(local, 'dmc-doc');
  }
  final xdg = environment['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'dmc-doc');
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  if (home == null) {
    throw StateError('Cannot find the home directory for Doc\'s data.');
  }
  return p.join(home, '.local', 'share', 'dmc-doc');
}

/// The lessons of one workspace, keyed by dmc's canonical workspace
/// identity (its fingerprint). Approved lessons are in `library/`; drafts
/// are in `drafts/` and are never matched.
class LessonStore {
  final Directory root;

  LessonStore(this.root);

  factory LessonStore.forWorkspace({
    required String dataDirectory,
    required String fingerprint,
    required String workspacePath,
  }) {
    final key = fingerprint.replaceFirst('sha256:', '');
    if (!RegExp(r'^[0-9a-f]{16,}$').hasMatch(key)) {
      throw FormatException('Unexpected workspace fingerprint: $fingerprint');
    }
    final store = LessonStore(
      Directory(p.join(dataDirectory, 'lessons', key.substring(0, 24))),
    );
    store.root.createSync(recursive: true);
    File(p.join(store.root.path, 'workspace.json')).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({'workspace': workspacePath, 'fingerprint': fingerprint})}\n',
    );
    return store;
  }

  Directory get library => Directory(p.join(root.path, 'library'));
  Directory get drafts => Directory(p.join(root.path, 'drafts'));

  List<Lesson> _read(Directory directory) {
    if (!directory.existsSync()) return const [];
    final lessons = <Lesson>[];
    for (final file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.md')) continue;
      try {
        lessons.add(Lesson.parse(file.readAsStringSync()));
      } on FormatException {
        // An unreadable file is skipped; `doc lesson show` reports why.
      }
    }
    lessons.sort((a, b) => b.created.compareTo(a.created));
    return lessons;
  }

  /// Approved lessons only.
  List<Lesson> approved() =>
      _read(library).where((lesson) => lesson.status == 'approved').toList();

  List<Lesson> pendingDrafts() => _read(drafts);

  File draftFile(String id) => File(p.join(drafts.path, '$id.md'));
  File libraryFile(String id) => File(p.join(library.path, '$id.md'));

  /// A new id: `<date>-<title slug>-<random>`.
  static String newId(String title, DateTime created, {Random? random}) {
    final slug = title
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final shortSlug = slug.length > 40
        ? slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '')
        : slug;
    final suffix = (random ?? Random.secure())
        .nextInt(0x10000)
        .toRadixString(16)
        .padLeft(4, '0');
    final date = created.toUtc().toIso8601String().substring(0, 10);
    return [date, if (shortSlug.isNotEmpty) shortSlug, suffix].join('-');
  }

  File saveDraft(Lesson lesson) {
    drafts.createSync(recursive: true);
    final file = draftFile(lesson.id);
    file.writeAsStringSync(lesson.withStatus('draft').toMarkdown());
    return file;
  }

  /// Resolve a draft by id or file path.
  File resolveDraft(String reference) {
    final asPath = File(reference);
    if (reference.endsWith('.md') && asPath.existsSync()) return asPath;
    final byId = draftFile(reference.replaceAll(RegExp(r'\.md$'), ''));
    if (byId.existsSync()) return byId;
    throw FileSystemException('No draft "$reference" in ${drafts.path}');
  }
}

/// A lesson that matched a task, with the overlapping files.
class LessonMatch {
  final Lesson lesson;
  final List<String> matchedFiles;

  const LessonMatch(this.lesson, this.matchedFiles);

  int get score => matchedFiles.length;
}

final _pathToken = RegExp(r'[A-Za-z0-9_\-./\\]+');

/// The candidate files for a task: path-like tokens in [task] that resolve
/// to [workspaceFiles] (an exact workspace-relative path, or a basename
/// that matches exactly one file), plus [extraFiles] (`--files`). A fixed,
/// deterministic rule; no model is involved.
Set<String> candidateFiles(
  String task,
  Iterable<String> workspaceFiles, {
  Iterable<String> extraFiles = const [],
}) {
  final known = {
    for (final file in workspaceFiles) ?normalizeWorkspacePath(file),
  };
  final byBasename = <String, List<String>>{};
  for (final file in known) {
    (byBasename[p.posix.basename(file)] ??= []).add(file);
  }
  final candidates = <String>{};
  for (final match in _pathToken.allMatches(task)) {
    final token = match[0]!.replaceAll(
      RegExp(r'^[.]+(?=[^./])|[.,:;!?]+$'),
      '',
    );
    if (!token.contains('.') && !token.contains('/')) continue;
    final path = normalizeWorkspacePath(token);
    if (path == null) continue;
    if (known.contains(path)) {
      candidates.add(path);
    } else if (!path.contains('/')) {
      final owners = byBasename[path];
      if (owners != null && owners.length == 1) candidates.add(owners.single);
    }
  }
  for (final file in extraFiles) {
    final path = normalizeWorkspacePath(file);
    if (path != null) candidates.add(path);
  }
  return candidates;
}

/// Score each approved lesson by how many of its files are candidates; keep
/// those scoring at least 1, highest first, newest first on ties, at most
/// [limit].
List<LessonMatch> matchLessons(
  Iterable<Lesson> lessons,
  Set<String> candidates, {
  int limit = 3,
}) {
  final matches = [
    for (final lesson in lessons)
      if (lesson.status == 'approved')
        LessonMatch(lesson, [
          for (final file in lesson.files)
            if (candidates.contains(file)) file,
        ]),
  ].where((match) => match.score >= 1).toList();
  matches.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    final byDate = b.lesson.created.compareTo(a.lesson.created);
    return byDate != 0 ? byDate : a.lesson.id.compareTo(b.lesson.id);
  });
  return matches.take(limit).toList();
}

/// The agent's first prompt: the brief, a blank line, then the task, or the
/// task alone when there is no brief or the user declined it.
String composeFirstPrompt({
  required String task,
  String? brief,
  required bool accepted,
}) => (accepted && brief != null && brief.trim().isNotEmpty)
    ? '${brief.trim()}\n\n${task.trim()}'
    : task.trim();
