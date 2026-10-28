import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// The compiled dmc these tests drive: `DMC_TEST_BIN`, else a fresh
/// `dart build cli` of the repository into a temporary directory.
Future<String> compiledDmc(Directory scratch) async {
  final given = Platform.environment['DMC_TEST_BIN'];
  if (given != null && given.isNotEmpty) return p.normalize(p.absolute(given));
  final docRoot = p.dirname(
    p.dirname(
      Isolate.resolvePackageUriSync(
        Uri.parse('package:dmc_doc/doc.dart'),
      )!.toFilePath(),
    ),
  );
  final repository = p.dirname(docRoot);
  final output = p.join(scratch.path, 'dmc-build');
  final build = await Process.run(Platform.resolvedExecutable, [
    'build',
    'cli',
    '-o',
    output,
  ], workingDirectory: repository);
  if (build.exitCode != 0) {
    throw StateError('dart build cli failed: ${build.stdout}\n${build.stderr}');
  }
  return p.join(
    output,
    'bundle',
    'bin',
    Platform.isWindows ? 'dmc.exe' : 'dmc',
  );
}
