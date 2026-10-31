import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Running `--setup` and `--test` commands in a folder that is not the
/// working copy (a bisect export or a timeline worktree).

/// The result of running one shell command.
class ShellRun {
  final int exitCode;
  final bool timedOut;
  final String output;
  const ShellRun(this.exitCode, this.timedOut, this.output);

  bool get passed => exitCode == 0 && !timedOut;
}

/// Run [command] with `/bin/sh -c` (POSIX) or `cmd /c` (Windows) in
/// [directory], with only [environment], killed after [timeout].
Future<ShellRun> runShell(
  String command,
  String directory,
  Duration timeout,
  Map<String, String> environment,
) async {
  final Process process;
  try {
    process = await Process.start(
      Platform.isWindows ? 'cmd' : '/bin/sh',
      Platform.isWindows ? ['/c', command] : ['-c', command],
      workingDirectory: directory,
      environment: environment,
      includeParentEnvironment: false,
    );
  } on ProcessException catch (error) {
    return ShellRun(
      127,
      false,
      'Could not start the command: ${error.message}\n',
    );
  }
  final output = StringBuffer();
  final done = Future.wait([
    process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(output.write),
    process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(output.write),
  ]);
  try {
    final code = await process.exitCode.timeout(timeout);
    await done.timeout(const Duration(seconds: 5), onTimeout: () => const []);
    return ShellRun(code, false, output.toString());
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return ShellRun(-1, true, output.toString());
  }
}

/// The last [lines] lines of [text], with a note of how many came before.
String tailLines(String text, int lines) {
  final all = const LineSplitter().convert(text.trimRight());
  return all.length <= lines
      ? all.join('\n')
      : '… (${all.length - lines} earlier lines)\n${all.skip(all.length - lines).join('\n')}';
}

/// Symlink each `--link` folder of [root] (the working copy) into
/// [directory], unless [directory] already has that path. Returns the
/// links it made.
List<String> linkDependencies(
  String root,
  String directory,
  List<String> links,
) {
  final made = <String>[];
  for (final link in links) {
    final relative = p.normalize(link);
    final target = p.join(directory, relative);
    if (FileSystemEntity.typeSync(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      continue; // Already there.
    }
    Directory(p.dirname(target)).createSync(recursive: true);
    Link(target).createSync(p.join(root, relative));
    made.add(target);
  }
  return made;
}
