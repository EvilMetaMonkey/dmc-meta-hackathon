import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'dmc_client.dart';
import 'redaction.dart';

/// Largest file (either side) whose lines are diffed.
const int abandonedFileLimitBytes = 64 * 1024;

/// Largest diff text sent to a model, in characters.
const int abandonedDiffLimitChars = 8000;

/// The work a checkpoint recorded, as a diff from its before state to its
/// after state: what a restore undoes.
///
/// dmc's JSON never carries file contents, so Doc asks dmc to export both
/// manifests (`dmc checkpoint export`) into a temporary directory outside
/// the workspace, diffs the changed files there, and deletes the copies.
/// Doc never reads the workspace itself. Files that are never sent
/// (`.env*`, `*.pem`, …), binaries and very large files are named only.
/// Returns null when the export is not possible (the reason is in [note]).
Future<String?> abandonedDiff(
  DmcClient dmc, {
  required String workspace,
  required String checkpointId,
  required List<({String path, String change})> files,
  void Function(String note)? note,
}) async {
  final temporary = Directory.systemTemp.createTempSync('doc-abandoned-');
  try {
    final before = p.join(temporary.path, 'before');
    final after = p.join(temporary.path, 'after');
    for (final (state, target) in [('before', before), ('after', after)]) {
      final result = await dmc.runJson([
        'checkpoint',
        'export',
        checkpointId,
        '--state',
        state,
        '--to',
        target,
      ], workspace: workspace);
      if (result['ok'] != true) {
        final errors = (result['errors'] as List? ?? const [])
            .whereType<Map>()
            .map((error) => error['message'])
            .join('; ');
        note?.call('Could not export the $state state for the diff: $errors');
        return null;
      }
    }
    final buffer = StringBuffer();
    for (final file in files) {
      if (buffer.length >= abandonedDiffLimitChars) break;
      buffer.writeln('--- ${file.path} (${file.change})');
      if (Redactor.isNeverSentFile(file.path)) {
        buffer.writeln('(contents never sent: secret-bearing file name)');
        continue;
      }
      final oldText = _readText(p.joinAll([before, ...file.path.split('/')]));
      final newText = _readText(p.joinAll([after, ...file.path.split('/')]));
      if (oldText == _binary || newText == _binary) {
        buffer.writeln('(binary or too large; not shown)');
        continue;
      }
      for (final line in unifiedLineDiff(oldText ?? '', newText ?? '')) {
        buffer.writeln(line);
      }
    }
    var text = buffer.toString();
    if (text.length > abandonedDiffLimitChars) {
      text =
          '${text.substring(0, abandonedDiffLimitChars)}\n… (diff cut at $abandonedDiffLimitChars characters)';
    }
    return text.trimRight();
  } on DmcException catch (error) {
    note?.call(
      'Could not export the checkpoint for the diff: ${error.message}',
    );
    return null;
  } finally {
    try {
      temporary.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: it is a temporary directory.
    }
  }
}

const String _binary = '\u0000binary';

/// The file's text, null when it is absent, or [_binary] when it is binary,
/// not UTF-8 or too large.
String? _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  if (file.lengthSync() > abandonedFileLimitBytes) return _binary;
  final bytes = file.readAsBytesSync();
  if (bytes.contains(0)) return _binary;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return _binary;
  }
}

/// A compact line diff: `-` removed, `+` added, ` ` context (2 lines
/// around each change), `@@` between separate hunks.
List<String> unifiedLineDiff(String before, String after, {int context = 2}) {
  final a = before.isEmpty ? <String>[] : const LineSplitter().convert(before);
  final b = after.isEmpty ? <String>[] : const LineSplitter().convert(after);
  final ops = <(String, String)>[];
  if (a.length * b.length > 4000000) {
    ops
      ..addAll(a.map((line) => ('-', line)))
      ..addAll(b.map((line) => ('+', line)));
  } else {
    final lengths = List.generate(
      a.length + 1,
      (_) => List<int>.filled(b.length + 1, 0),
    );
    for (var i = a.length - 1; i >= 0; i--) {
      for (var j = b.length - 1; j >= 0; j--) {
        lengths[i][j] = a[i] == b[j]
            ? lengths[i + 1][j + 1] + 1
            : (lengths[i + 1][j] >= lengths[i][j + 1]
                  ? lengths[i + 1][j]
                  : lengths[i][j + 1]);
      }
    }
    var i = 0;
    var j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        ops.add((' ', a[i++]));
        j++;
      } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
        ops.add(('-', a[i++]));
      } else {
        ops.add(('+', b[j++]));
      }
    }
    while (i < a.length) {
      ops.add(('-', a[i++]));
    }
    while (j < b.length) {
      ops.add(('+', b[j++]));
    }
  }
  final keep = List<bool>.filled(ops.length, false);
  for (var k = 0; k < ops.length; k++) {
    if (ops[k].$1 == ' ') continue;
    for (var c = k - context; c <= k + context; c++) {
      if (c >= 0 && c < ops.length) keep[c] = true;
    }
  }
  final lines = <String>[];
  var gap = false;
  for (var k = 0; k < ops.length; k++) {
    if (!keep[k]) {
      gap = true;
      continue;
    }
    if (gap && lines.isNotEmpty) lines.add('@@');
    gap = false;
    lines.add('${ops[k].$1}${ops[k].$2}');
  }
  return lines;
}
