import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'agent_hooks.dart';
import 'checkpoint_service.dart';
import 'checkpoint_restore_service.dart';
import 'daemon.dart';
import 'doctor.dart';
import 'diff.dart';
import 'gc.dart';
import 'init.dart';
import 'log.dart';
import 'marks.dart';
import 'machine_output.dart';
import 'restore.dart';
import 'snap.dart';
import 'status.dart';
import 'task.dart';
import 'ui.dart';
import 'version.dart';
import 'watcher.dart';

ArgParser _addPreviewFlags(ArgParser command) {
  command.addFlag(
    'dry-run',
    negatable: false,
    help: 'Preview the restore without modifying the file',
  );
  command.addFlag('preview', negatable: false, help: 'Alias for --dry-run');
  return command;
}

ArgParser _addRestoreCommand(ArgParser parser, String name) {
  final command = _addPreviewFlags(parser.addCommand(name));
  command.addOption('id', help: 'Specific snapshot ID to target');
  command.addOption('burst', help: 'Specific burst ID to target');
  command.addOption('task', help: 'Specific task name to target');
  command.addOption('mark', help: 'Specific mark name to target');
  return command;
}

Future<int> _runRedoCommand(ArgResults command) async {
  final dryRun =
      (command['dry-run'] as bool? ?? false) ||
      (command['preview'] as bool? ?? false);
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;
  final taskName = _parseStringOption(command, 'task');
  final markName = _parseStringOption(command, 'mark');

  final selectedTargets = [
    if (parsedBurstId.id != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --burst, --task, or --mark.');
    return 1;
  }

  if (selectedTargets.isNotEmpty) {
    if (command.rest.isNotEmpty) {
      print(
        '[DMC] Error: Do not specify a file when using --burst, --task, or --mark.',
      );
      print(
        'Usage: dmc redo [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
      );
      return 1;
    }

    final result = await redoFile(
      '',
      burstId: parsedBurstId.id,
      taskName: taskName,
      markName: markName,
      dryRun: dryRun,
    );
    return result.hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to redo.');
    print(
      'Usage: dmc redo [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
    );
    return 1;
  }

  final result = await redoFile(command.rest.first, dryRun: dryRun);
  return result.hadError ? 1 : 0;
}

Future<int> _runLogCommand(ArgResults command) async {
  final bursts = command['bursts'] as bool? ?? false;
  final tasks = command['tasks'] as bool? ?? false;
  if (bursts && tasks) {
    print('[DMC] Error: Use either --bursts or --tasks, not both.');
    return 1;
  }

  return showLogs(bursts: bursts, tasks: tasks);
}

Future<int> _runStatusCommand() async {
  return showStatus();
}

Future<int> _runStartCommand() {
  return startDaemon();
}

Future<int> _runStopCommand() {
  return stopDaemon();
}

Future<int> _runDoctorCommand() async {
  final hadIssues = await runDoctor();
  return hadIssues ? 1 : 0;
}

Future<int> _runTaskCommand(ArgResults command) async {
  final subcommand = command.command;
  if (subcommand == null) {
    print('Usage: dmc task <start|end>');
    return 1;
  }

  switch (subcommand.name) {
    case 'start':
      if (subcommand.rest.isEmpty) {
        print('[DMC] Error: Please specify a task name.');
        return 1;
      }
      return startTask(subcommand.rest.join(' '));
    case 'end':
      return endTask();
    default:
      print('Usage: dmc task <start|end>');
      return 1;
  }
}

Future<int> _runMarkCommand(ArgResults command) async {
  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a mark name.');
    return 1;
  }

  return createMark(command.rest.join(' '));
}

Future<int> _runMarksCommand() async {
  return showMarks();
}

Future<int> _runGcCommand(ArgResults command) {
  return runGc(dryRun: command['dry-run'] as bool? ?? false);
}

Future<int> _runSnapCommand() async {
  return takeManualSnapshot();
}

Future<int> _runUiCommand() {
  return runInteractiveUi();
}

bool _wantsMachineOutput(List<String> args) =>
    args.contains('--json') &&
    (args.contains('checkpoint') || args.contains('capabilities'));

String _machineCommandName(List<String> args) {
  if (args.contains('capabilities')) return 'capabilities';
  final checkpoint = args.indexOf('checkpoint');
  if (checkpoint >= 0 && checkpoint + 1 < args.length) {
    final name = args[checkpoint + 1];
    if (!name.startsWith('-')) return 'checkpoint.$name';
  }
  return 'checkpoint';
}

Future<int> _runCheckpointCommand(ArgResults command) async {
  final subcommand = command.command;
  if (subcommand == null) {
    print(
      'Usage: dmc checkpoint <begin|close|list|show|diff|restore|redo|recover|release>',
    );
    return 2;
  }
  final json = subcommand['json'] as bool? ?? false;
  final schemaFailure = validateMachineSchemaRequest(
    'checkpoint.${subcommand.name}',
    subcommand['schema-version'] as String?,
    json: json,
  );
  if (schemaFailure != null) {
    if (json) {
      print(schemaFailure.withWorkspace(Directory.current.path).encode());
    } else {
      print('[DMC] Error: ${schemaFailure.errors.single.message}');
    }
    return schemaFailure.exitCode;
  }
  final service = CheckpointService();
  Future<CommandResult> invoke(Future<CommandResult> Function() operation) {
    if (!json) return operation();
    return runZoned(
      operation,
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => stderr.writeln(message),
      ),
    );
  }

  late final CommandResult result;
  switch (subcommand.name) {
    case 'list':
      if (subcommand.rest.isNotEmpty) {
        result = machineFailure(
          'checkpoint.list',
          2,
          'unexpected_arguments',
          'checkpoint list does not accept positional arguments.',
        );
      } else {
        final rawLimit = subcommand['limit'] as String?;
        final limit = rawLimit == null ? 50 : int.tryParse(rawLimit);
        if (limit == null) {
          result = machineFailure(
            'checkpoint.list',
            2,
            'invalid_limit',
            'Checkpoint list limit must be an integer.',
          );
        } else {
          result = await invoke(() => service.list(limit: limit));
        }
      }
      break;
    case 'begin':
      if (subcommand.rest.isNotEmpty) {
        result = machineFailure(
          'checkpoint.begin',
          2,
          'unexpected_arguments',
          'checkpoint begin does not accept positional arguments.',
        );
      } else {
        result = await invoke(
          () => service.begin(
            label: subcommand['label'] as String?,
            source: subcommand['source'] as String? ?? 'manual',
          ),
        );
      }
      break;
    case 'restore':
    case 'redo':
      if (subcommand.rest.length != 1) {
        result = machineFailure(
          'checkpoint.${subcommand.name}',
          2,
          'checkpoint_id_required',
          'Specify exactly one checkpoint ID.',
        );
      } else if ((subcommand['apply'] as bool) &&
          (subcommand['dry-run'] as bool)) {
        result = machineFailure(
          'checkpoint.${subcommand.name}',
          2,
          'conflicting_modes',
          'Use either --apply or --dry-run, not both.',
        );
      } else {
        final restoreService = CheckpointRestoreService();
        final id = subcommand.rest.single;
        result = subcommand.name == 'restore'
            ? await invoke(
                () => restoreService.restore(
                  id,
                  apply: subcommand['apply'] as bool,
                ),
              )
            : await invoke(
                () =>
                    restoreService.redo(id, apply: subcommand['apply'] as bool),
              );
      }
      break;
    case 'recover':
      final resume = subcommand['resume'] as bool;
      final rollback = subcommand['rollback'] as bool;
      if (subcommand.rest.length != 1) {
        result = machineFailure(
          'checkpoint.recover',
          2,
          'operation_id_required',
          'Specify exactly one operation ID.',
        );
      } else if (resume == rollback) {
        result = machineFailure(
          'checkpoint.recover',
          2,
          'recovery_mode_required',
          'Specify exactly one of --resume or --rollback.',
        );
      } else {
        result = await invoke(
          () => CheckpointRestoreService().recover(
            subcommand.rest.single,
            rollback: rollback,
            preview: subcommand['preview'] as bool,
          ),
        );
      }
      break;
    case 'close':
    case 'show':
    case 'diff':
    case 'release':
      if (subcommand.rest.length != 1) {
        result = machineFailure(
          'checkpoint.${subcommand.name}',
          2,
          'checkpoint_id_required',
          'Specify exactly one checkpoint ID.',
        );
      } else {
        final id = subcommand.rest.single;
        result = switch (subcommand.name) {
          'close' => await invoke(() => service.close(id)),
          'show' => await invoke(() => service.show(id)),
          'diff' => await invoke(() => service.diff(id)),
          'release' => await invoke(() => service.release(id)),
          _ => throw StateError('Unreachable checkpoint command'),
        };
      }
      break;
    default:
      result = machineFailure(
        'checkpoint.${subcommand.name}',
        2,
        'unknown_checkpoint_command',
        'Unknown checkpoint command: ${subcommand.name}',
      );
  }
  if (json) {
    print(result.withWorkspace(Directory.current.path).encode());
  } else {
    final lines = {'restore', 'redo', 'recover'}.contains(subcommand.name)
        ? checkpointOperationHumanLines(result)
        : checkpointHumanLines(result);
    for (final line in lines) {
      print(line);
    }
  }
  return result.exitCode;
}

int _runCapabilitiesCommand({
  required bool json,
  required String? requestedSchemaVersion,
}) {
  final schemaFailure = validateMachineSchemaRequest(
    'capabilities',
    requestedSchemaVersion,
    json: json,
  );
  if (schemaFailure != null) {
    if (json) {
      print(schemaFailure.withWorkspace(Directory.current.path).encode());
    } else {
      print('[DMC] Error: ${schemaFailure.errors.single.message}');
    }
    return schemaFailure.exitCode;
  }
  const result = CommandResult(
    command: 'capabilities',
    exitCode: 0,
    data: {
      'contract': 'haven-checkpoint-v1',
      'machineSchemaVersions': supportedMachineSchemaVersions,
      'checkpointManifestVersions': supportedCheckpointManifestVersions,
      'commands': [
        'checkpoint.begin',
        'checkpoint.close',
        'checkpoint.list',
        'checkpoint.show',
        'checkpoint.diff',
        'checkpoint.restore',
        'checkpoint.redo',
        'checkpoint.recover',
        'checkpoint.release',
      ],
      'features': {
        'checkpointApply': true,
        'checkpointRedo': true,
        'operationRecovery': true,
        'operationRecoveryPreview': true,
        'previewByDefault': true,
        'conflictBlocksAllWrites': true,
        'fileContentsInJson': false,
      },
      'cancellation': {
        'capture': 'detect_interrupted_checkpoint',
        'apply': 'detect_and_recover_journal',
        'requiredFollowUp': 'checkpoint.list_or_show_then_recover',
      },
      'checkpointApply': true,
    },
  );
  if (json) {
    print(result.withWorkspace(Directory.current.path).encode());
  } else {
    print('[DMC] Machine schema: 1');
    print('[DMC] Checkpoint manifest: 1');
    print('[DMC] Checkpoint apply: available');
  }
  return 0;
}

({int? id, bool isValid}) _parseSnapshotId(ArgResults command) {
  return _parseIntegerOption(command, 'id');
}

({int? id, bool isValid}) _parseBurstId(ArgResults command) {
  return _parseIntegerOption(command, 'burst');
}

String? _parseStringOption(ArgResults command, String optionName) {
  final rawValue = command[optionName] as String?;
  if (rawValue == null) {
    return null;
  }

  final trimmedValue = rawValue.trim();
  return trimmedValue.isEmpty ? null : trimmedValue;
}

({int? id, bool isValid}) _parseIntegerOption(
  ArgResults command,
  String optionName,
) {
  final rawId = command[optionName] as String?;
  if (rawId == null) {
    return (id: null, isValid: true);
  }

  final parsedId = int.tryParse(rawId);
  if (parsedId == null) {
    print('[DMC] Error: --$optionName must be an integer.');
    return (id: null, isValid: false);
  }

  return (id: parsedId, isValid: true);
}

Future<int> _runRestoreCommand(ArgResults command) async {
  final parsedId = _parseSnapshotId(command);
  if (!parsedId.isValid) return 1;
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;
  final taskName = _parseStringOption(command, 'task');
  final markName = _parseStringOption(command, 'mark');

  final selectedTargets = [
    if (parsedId.id != null) 'id',
    if (parsedBurstId.id != null) 'burst',
    if (taskName != null) 'task',
    if (markName != null) 'mark',
  ];
  if (selectedTargets.length > 1) {
    print('[DMC] Error: Use only one of --id, --burst, --task, or --mark.');
    return 1;
  }

  final dryRun =
      (command['dry-run'] as bool? ?? false) ||
      (command['preview'] as bool? ?? false);

  if (parsedBurstId.id != null || taskName != null || markName != null) {
    if (command.rest.isNotEmpty) {
      print(
        '[DMC] Error: Do not specify a file when using --burst, --task, or --mark.',
      );
      print(
        'Usage: dmc ${command.name} [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
      );
      return 1;
    }

    final result = await restoreFile(
      '',
      burstId: parsedBurstId.id,
      taskName: taskName,
      markName: markName,
      dryRun: dryRun,
      commandName: command.name!,
    );
    return result.hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to restore.');
    print(
      'Usage: dmc ${command.name} [--id <snapshot-id>] [--dry-run|--preview] [--burst <burst-id>|--task <name>|--mark <name>] <filepath>',
    );
    return 1;
  }

  final result = await restoreFile(
    command.rest.first,
    id: parsedId.id,
    dryRun: dryRun,
    commandName: command.name!,
  );
  return result.hadError ? 1 : 0;
}

Future<int> _runDiffCommand(ArgResults command) async {
  final parsedId = _parseSnapshotId(command);
  if (!parsedId.isValid) return 1;
  final parsedBurstId = _parseBurstId(command);
  if (!parsedBurstId.isValid) return 1;

  if (parsedId.id != null && parsedBurstId.id != null) {
    print('[DMC] Error: Use either --id or --burst, not both.');
    return 1;
  }

  if (parsedBurstId.id != null) {
    if (command.rest.isNotEmpty) {
      print('[DMC] Error: Do not specify a file when using --burst.');
      print(
        'Usage: dmc diff [--id <snapshot-id> | --burst <burst-id>] <filepath>',
      );
      return 1;
    }

    final hadError = await showDiff('', burstId: parsedBurstId.id);
    return hadError ? 1 : 0;
  }

  if (command.rest.isEmpty) {
    print('[DMC] Error: Please specify a file to diff.');
    print(
      'Usage: dmc diff [--id <snapshot-id> | --burst <burst-id>] <filepath>',
    );
    return 1;
  }

  final hadError = await showDiff(command.rest.first, id: parsedId.id);
  return hadError ? 1 : 0;
}

/// Parse command-line arguments and execute the appropriate command
Future<int> runCli(List<String> args) async {
  // Agent hooks bypass normal parsing: they must exit 0 with empty stdout
  // even for arguments this version does not understand.
  if (args.isNotEmpty && args.first == 'agent-hook') {
    return runAgentHookCommand(args.sublist(1));
  }
  try {
    return await _runCli(args);
  } on FormatException catch (e) {
    if (_wantsMachineOutput(args)) {
      print(
        machineFailure(
          _machineCommandName(args),
          2,
          'invalid_arguments',
          e.message,
        ).withWorkspace(Directory.current.path).encode(),
      );
    } else {
      print('[DMC] Invalid arguments or configuration: ${e.message}');
    }
    return 2;
  } on ArgumentError catch (e) {
    final exitCode = _wantsMachineOutput(args) ? 2 : 1;
    if (_wantsMachineOutput(args)) {
      print(
        machineFailure(
          _machineCommandName(args),
          exitCode,
          'invalid_arguments',
          '${e.message}',
        ).withWorkspace(Directory.current.path).encode(),
      );
    } else {
      print('[DMC] Error: ${e.message}');
    }
    return exitCode;
  } catch (e) {
    if (_wantsMachineOutput(args)) {
      print(
        machineFailure(
          _machineCommandName(args),
          1,
          'internal_error',
          e.toString(),
        ).encode(),
      );
    } else {
      print('[DMC] Error: $e');
    }
    return 1;
  }
}

Future<int> _runCli(List<String> args) async {
  final parser = ArgParser();
  parser.addFlag('help', abbr: 'h', negatable: false, help: 'Show usage');
  parser.addFlag(
    'version',
    negatable: false,
    help: 'Print the current version',
  );
  parser.addCommand('init');
  parser.addCommand('start');
  parser.addCommand('stop');
  parser.addCommand('watch');
  parser.addCommand('status');
  parser.addCommand('doctor');
  parser.addCommand('ui');
  parser.addCommand('snap');
  final capabilitiesCommand = parser.addCommand('capabilities');
  capabilitiesCommand.addFlag(
    'json',
    negatable: false,
    help: 'Print the versioned machine-readable result',
  );
  capabilitiesCommand.addOption(
    'schema-version',
    help: 'Require a supported machine schema version',
  );
  final checkpointCommand = parser.addCommand('checkpoint');
  final checkpointBegin = checkpointCommand.addCommand('begin');
  final checkpointList = checkpointCommand.addCommand('list');
  checkpointList.addOption(
    'limit',
    defaultsTo: '50',
    help: 'Maximum checkpoints to return (1-1000)',
  );
  checkpointBegin.addOption('label', help: 'Human-readable checkpoint label');
  checkpointBegin.addOption(
    'source',
    defaultsTo: 'manual',
    help: 'Originating tool or integration',
  );
  final checkpointRestore = checkpointCommand.addCommand('restore');
  final checkpointRedo = checkpointCommand.addCommand('redo');
  for (final command in [checkpointRestore, checkpointRedo]) {
    command.addFlag(
      'dry-run',
      negatable: false,
      help: 'Explicitly preview without changing the workspace',
    );
    command.addFlag(
      'apply',
      negatable: false,
      help: 'Apply the journaled operation',
    );
  }
  final checkpointRecover = checkpointCommand.addCommand('recover');
  checkpointRecover.addFlag(
    'preview',
    negatable: false,
    help:
        'Inspect recovery targets and conflicts without changing recovery state',
  );
  checkpointRecover.addFlag(
    'resume',
    negatable: false,
    help: 'Continue the recorded operation',
  );
  checkpointRecover.addFlag(
    'rollback',
    negatable: false,
    help: 'Return all targets to their recorded pre-operation state',
  );
  for (final checkpointSubcommand in [
    checkpointBegin,
    checkpointList,
    checkpointCommand.addCommand('close'),
    checkpointCommand.addCommand('show'),
    checkpointCommand.addCommand('diff'),
    checkpointRestore,
    checkpointRedo,
    checkpointRecover,
    checkpointCommand.addCommand('release'),
  ]) {
    checkpointSubcommand.addFlag(
      'json',
      negatable: false,
      help: 'Print exactly one versioned JSON result',
    );
    checkpointSubcommand.addOption(
      'schema-version',
      help: 'Require a supported machine schema version',
    );
  }
  final gcCommand = parser.addCommand('gc');
  gcCommand.addFlag('dry-run', negatable: false, help: 'Preview cleanup only');
  parser.addCommand('mark');
  parser.addCommand('marks');
  final taskCommand = parser.addCommand('task');
  taskCommand.addCommand('start');
  taskCommand.addCommand('end');
  final logCommand = parser.addCommand('log');
  logCommand.addFlag(
    'bursts',
    negatable: false,
    help: 'Group recent history by burst',
  );
  logCommand.addFlag(
    'tasks',
    negatable: false,
    help: 'Group recent history by task',
  );
  _addRestoreCommand(parser, 'undo');
  _addRestoreCommand(parser, 'restore');
  final redoCommand = _addPreviewFlags(parser.addCommand('redo'));
  redoCommand.addOption('burst', help: 'Specific burst ID to target');
  redoCommand.addOption('task', help: 'Specific task name to target');
  redoCommand.addOption('mark', help: 'Specific mark name to target');
  final diffCommand = parser.addCommand('diff');
  diffCommand.addOption('id', help: 'Specific snapshot ID to target');
  diffCommand.addOption('burst', help: 'Specific burst ID to target');

  for (final command in parser.commands.values) {
    command.addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Show command usage',
    );
    for (final subcommand in command.commands.values) {
      subcommand.addFlag('help', abbr: 'h', negatable: false);
    }
  }

  final results = parser.parse(args);

  if (results['version'] as bool) {
    print('dmc version $dmcVersion');
    return 0;
  }

  final command = results.command;
  if (command != null && (command['help'] as bool? ?? false)) {
    print('Usage: dmc ${command.name} [options]');
    print(parser.commands[command.name]!.usage);
    return 0;
  }
  if (command?.command != null &&
      (command!.command!['help'] as bool? ?? false)) {
    print('Usage: dmc ${command.name} ${command.command!.name}');
    print(
      parser.commands[command.name]!.commands[command.command!.name]!.usage,
    );
    return 0;
  }

  if (command == null || results['help'] as bool) {
    print('Usage: dmc <command>');
    print('Commands:');
    print('  init                 Initialize DMC in the current directory');
    print('  start                Start the watcher as a background daemon');
    print('  stop                 Stop the background watcher daemon');
    print('  watch                Watch for file changes in the foreground');
    print('  status               Show vault health and active config');
    print('  doctor               Check DB access and snapshot consistency');
    print('  ui                   Launch the interactive terminal dashboard');
    print('  snap                 Capture a manual workspace snapshot');
    print(
      '  capabilities --json [--schema-version 1]  Report the machine contract',
    );
    print('  checkpoint begin [--label <text>] [--source <name>] [--json]');
    print('  checkpoint list [--limit <count>] [--json]');
    print('  checkpoint close|show|diff|release <id> [--json]');
    print('  checkpoint restore|redo <id> [--dry-run|--apply] [--json]');
    print(
      '  checkpoint recover <operation-id> (--resume|--rollback) [--preview] [--json]',
    );
    print(
      '  agent-hook <muse-code|claude-code> <event>  Checkpoint an agent turn (called by agent hooks)',
    );
    print(
      '  gc [--dry-run]       Prune expired snapshots using retention config',
    );
    print('  task start <name>    Start assigning snapshots to a task');
    print('  task end             Stop assigning snapshots to a task');
    print('  mark <name>          Save a mark for the latest burst');
    print('  marks                List saved marks');
    print('  log [--bursts|--tasks]       Show recent backup history');
    print(
      '  undo [--id <id>|--burst <id>|--task <name>|--mark <name>] [--dry-run]     Restore a file to a previous state',
    );
    print(
      '  restore [--id <id>|--burst <id>|--task <name>|--mark <name>] [--dry-run]  Alias for undo',
    );
    print(
      '  redo [--burst <id>|--task <name>|--mark <name>] [--dry-run]  Restore the last undone state',
    );
    print(
      '  diff [--id <id>|--burst <id>]    Show a colored diff against a snapshot',
    );
    return 0;
  }

  const noFileArguments = {
    'init',
    'start',
    'stop',
    'watch',
    'status',
    'doctor',
    'ui',
    'snap',
    'gc',
    'marks',
    'log',
    'capabilities',
  };
  if ((noFileArguments.contains(command.name) && command.rest.isNotEmpty) ||
      ({'restore', 'undo', 'redo', 'diff'}.contains(command.name) &&
          command.rest.length > 1)) {
    throw FormatException(
      'Unexpected extra arguments for ${command.name}. Run dmc ${command.name} --help.',
    );
  }
  switch (command.name) {
    case 'init':
      await initDmc();
      return 0;
    case 'start':
      return _runStartCommand();
    case 'stop':
      return _runStopCommand();
    case 'watch':
      return watchDmc();
    case 'snap':
      return _runSnapCommand();
    case 'capabilities':
      return _runCapabilitiesCommand(
        json: command['json'] as bool? ?? false,
        requestedSchemaVersion: command['schema-version'] as String?,
      );
    case 'checkpoint':
      return _runCheckpointCommand(command);
    case 'gc':
      return _runGcCommand(command);
    case 'status':
      return _runStatusCommand();
    case 'doctor':
      return _runDoctorCommand();
    case 'ui':
      return _runUiCommand();
    case 'task':
      return _runTaskCommand(command);
    case 'mark':
      return _runMarkCommand(command);
    case 'marks':
      return _runMarksCommand();
    case 'log':
      return _runLogCommand(command);
    case 'undo':
    case 'restore':
      return _runRestoreCommand(command);
    case 'redo':
      return _runRedoCommand(command);
    case 'diff':
      return _runDiffCommand(command);
    default:
      print('Unknown command: ${command.name}');
      print('Run "dmc" for usage information');
      return 1;
  }
}
