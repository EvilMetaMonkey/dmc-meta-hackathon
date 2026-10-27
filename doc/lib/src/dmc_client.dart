import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Doc talks to dmc only by running the dmc executable with
/// `--json --schema-version 1`. It never opens dmc's database or reads or
/// writes workspace files itself.
class DmcException implements Exception {
  final String message;

  const DmcException(this.message);

  @override
  String toString() => message;
}

/// Apple ships an unrelated `dmc` (Disk Mount Conditioner) here. Doc never
/// runs it.
const String appleDmcPath = '/usr/bin/dmc';

/// Commands Doc needs from dmc's machine contract.
const List<String> requiredDmcCommands = [
  'checkpoint.show',
  'checkpoint.diff',
  'checkpoint.list',
];

class DmcClient {
  final String executable;
  final Duration timeout;

  const DmcClient(
    this.executable, {
    this.timeout = const Duration(seconds: 60),
  });

  /// Find dmc: [explicit] (`--dmc`), then `DMC_BIN`, then each `dmc` on PATH.
  /// Every candidate must pass `dmc capabilities --json --schema-version 1`.
  /// An explicit or `DMC_BIN` path that fails is an error; PATH candidates
  /// that fail (an old dmc, Apple's `/usr/bin/dmc`) are skipped and listed.
  static Future<DmcClient> locate({
    String? explicit,
    required Map<String, String> environment,
  }) async {
    final named = explicit ?? environment['DMC_BIN'];
    if (named != null && named.trim().isNotEmpty) {
      final source = explicit != null ? '--dmc' : 'DMC_BIN';
      final client = DmcClient(p.normalize(p.absolute(named.trim())));
      final problem = await client._checkCapabilities();
      if (problem != null) {
        throw DmcException(
          '$source points at ${client.executable}, which $problem',
        );
      }
      return client;
    }
    final skipped = <String>[];
    for (final candidate in _pathCandidates(environment)) {
      if (p.equals(candidate, appleDmcPath)) {
        skipped.add('$candidate (Apple\'s Disk Mount Conditioner, not dmc)');
        continue;
      }
      final client = DmcClient(candidate);
      final problem = await client._checkCapabilities();
      if (problem == null) return client;
      skipped.add('$candidate ($problem)');
    }
    throw DmcException(
      [
        'No compatible dmc was found. Pass --dmc <path to the dmc bundle executable> or set DMC_BIN.',
        if (skipped.isNotEmpty) 'Skipped on PATH: ${skipped.join('; ')}.',
      ].join(' '),
    );
  }

  static Iterable<String> _pathCandidates(
    Map<String, String> environment,
  ) sync* {
    final name = Platform.isWindows ? 'dmc.exe' : 'dmc';
    final seen = <String>{};
    final pathValue = environment['PATH'] ?? environment['Path'] ?? '';
    for (final directory in pathValue.split(Platform.isWindows ? ';' : ':')) {
      if (directory.trim().isEmpty) continue;
      final candidate = p.normalize(p.join(directory.trim(), name));
      if (!seen.add(candidate)) continue;
      if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.file) {
        yield candidate;
      }
    }
  }

  /// Null when [executable] speaks dmc's machine contract, else why not.
  Future<String?> _checkCapabilities() async {
    if (FileSystemEntity.typeSync(executable) != FileSystemEntityType.file) {
      return 'does not exist';
    }
    final Map<String, Object?> envelope;
    try {
      envelope = await _run([
        'capabilities',
        '--json',
        '--schema-version',
        '1',
      ]);
    } on DmcException catch (error) {
      return 'is not a compatible dmc (${error.message})';
    }
    final data = envelope['data'];
    if (envelope['ok'] != true || data is! Map) {
      return 'did not report capabilities';
    }
    if (data['contract'] != 'haven-checkpoint-v1' ||
        data['machineSchemaVersions'] is! List ||
        !(data['machineSchemaVersions'] as List).contains(1)) {
      return 'does not support machine schema 1';
    }
    final commands = data['commands'];
    final missing = [
      for (final command in requiredDmcCommands)
        if (commands is! List || !commands.contains(command)) command,
    ];
    if (missing.isNotEmpty) return 'lacks ${missing.join(', ')}';
    return null;
  }

  /// Run one dmc command in [workspace] with `--json --schema-version 1` and
  /// return its envelope. A non-zero exit still returns the envelope; check
  /// `ok` and `errors`.
  Future<Map<String, Object?>> runJson(
    List<String> args, {
    required String workspace,
  }) =>
      _run([...args, '--json', '--schema-version', '1'], workspace: workspace);

  Future<Map<String, Object?>> _run(
    List<String> args, {
    String? workspace,
  }) async {
    final ProcessResult result;
    try {
      result = await Process.run(
        executable,
        args,
        workingDirectory: workspace,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
    } on ProcessException catch (error) {
      throw DmcException('could not run: ${error.message}');
    } on TimeoutException {
      throw DmcException('no answer within ${timeout.inSeconds} s');
    }
    final stdout = (result.stdout as String).trim();
    try {
      final decoded = jsonDecode(stdout);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      // Reported below.
    }
    final firstLine = stdout.isEmpty
        ? (result.stderr as String).trim().split('\n').first
        : stdout.split('\n').first;
    throw DmcException(
      'printed no JSON envelope (exit ${result.exitCode}${firstLine.isEmpty ? '' : ': $firstLine'})',
    );
  }
}
