import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'agent_hooks.dart';

/// Where an agent's hook configuration is written.
enum HookScope { project, local, user }

/// The scope used when `--scope` is omitted. Both were verified by probe.
/// Muse Code 1.4.13 also runs `.muse/hooks.json`, but only in a trusted
/// workspace and silently skips it otherwise, so the user settings file,
/// which always runs, is the default. See docs/AGENT-HOOKS.md.
HookScope defaultHookScope(HookAgent agent) => switch (agent) {
  HookAgent.claudeCode => HookScope.local,
  HookAgent.museCode => HookScope.user,
};

/// Hook events dmc registers for [agent].
List<String> dmcHookEvents(HookAgent agent) => switch (agent) {
  HookAgent.museCode => const [
    'UserPromptSubmit',
    'Stop',
    'StopFailure',
    'Interrupt',
    'SessionEnd',
  ],
  HookAgent.claudeCode => const [
    'UserPromptSubmit',
    'Stop',
    'StopFailure',
    'SessionEnd',
  ],
};

/// Seconds an agent waits for a dmc hook. Begin and close each scan the
/// workspace, which cannot be interrupted safely.
const int dmcHookTimeoutSeconds = 60;

/// The config file for [agent] at [scope], or null if the agent has no such
/// scope. [workspaceRoot] is required for project and local scopes.
String? hookConfigPath(
  HookAgent agent,
  HookScope scope, {
  required String? workspaceRoot,
  required String homePath,
}) {
  String inWorkspace(List<String> parts) {
    if (workspaceRoot == null) {
      throw StateError('A workspace is required for ${scope.name} scope.');
    }
    return p.joinAll([workspaceRoot, ...parts]);
  }

  return switch ((agent, scope)) {
    (HookAgent.claudeCode, HookScope.project) => inWorkspace([
      '.claude',
      'settings.json',
    ]),
    (HookAgent.claudeCode, HookScope.local) => inWorkspace([
      '.claude',
      'settings.local.json',
    ]),
    (HookAgent.claudeCode, HookScope.user) => p.join(
      homePath,
      '.claude',
      'settings.json',
    ),
    (HookAgent.museCode, HookScope.project) => inWorkspace([
      '.muse',
      'hooks.json',
    ]),
    (HookAgent.museCode, HookScope.local) => null,
    (HookAgent.museCode, HookScope.user) => p.join(
      homePath,
      '.config',
      'muse',
      'settings.json',
    ),
  };
}

final _shellSafe = RegExp(r'^[A-Za-z0-9_./:@%+=,-]+$');

/// Quote [value] for a POSIX shell (`$SHELL -c`, Git Bash on Windows).
String shellQuote(String value) =>
    _shellSafe.hasMatch(value) ? value : "'${value.replaceAll("'", "'\\''")}'";

/// The exact handler command dmc writes, and matches on uninstall.
String dmcHookCommand(String dmcCommand, HookAgent agent, String event) =>
    '$dmcCommand agent-hook ${agent.id} $event';

Map<String, Object?> dmcHookHandler(
  String dmcCommand,
  HookAgent agent,
  String event,
) => {
  'type': 'command',
  'command': dmcHookCommand(dmcCommand, agent, event),
  'timeout': dmcHookTimeoutSeconds,
  // Muse Code requires Interrupt handlers to be async.
  if (agent == HookAgent.museCode && event == 'Interrupt') 'async': true,
};

/// The result of planning a config change.
class HookConfigPlan {
  final Map<String, Object?> after;
  final List<String> added;
  final List<String> removed;

  const HookConfigPlan(this.after, this.added, this.removed);

  bool get changed => added.isNotEmpty || removed.isNotEmpty;
}

Map<String, Object?> _copy(Map<String, Object?> config) =>
    jsonDecode(jsonEncode(config)) as Map<String, Object?>;

Map<String, Object?> _hooksObject(Map<String, Object?> config) {
  final hooks = config['hooks'];
  if (hooks == null) return config['hooks'] = <String, Object?>{};
  if (hooks is! Map<String, Object?>) {
    throw const FormatException('"hooks" must be a JSON object.');
  }
  return hooks;
}

List<Object?> _eventGroups(Map<String, Object?> hooks, String event) {
  final groups = hooks[event];
  if (groups == null) return hooks[event] = <Object?>[];
  if (groups is! List<Object?>) {
    throw FormatException('"hooks.$event" must be a JSON array.');
  }
  return groups;
}

Iterable<Map<String, Object?>> _handlers(Object? group) sync* {
  if (group is! Map<String, Object?>) return;
  final handlers = group['hooks'];
  if (handlers is! List<Object?>) return;
  yield* handlers.whereType<Map<String, Object?>>();
}

bool _hasCommand(List<Object?> groups, String command) => groups.any(
  (group) => _handlers(group).any((handler) => handler['command'] == command),
);

/// Add dmc's handlers to [config] where they are missing. Existing entries,
/// dmc's included, are never modified.
HookConfigPlan planHookInstall(
  Map<String, Object?> config,
  HookAgent agent,
  String dmcCommand,
) {
  final after = _copy(config);
  final hooks = _hooksObject(after);
  final added = <String>[];
  for (final event in dmcHookEvents(agent)) {
    final groups = _eventGroups(hooks, event);
    if (_hasCommand(groups, dmcHookCommand(dmcCommand, agent, event))) {
      continue;
    }
    groups.add({
      'matcher': '*',
      'hooks': [dmcHookHandler(dmcCommand, agent, event)],
    });
    added.add(event);
  }
  return HookConfigPlan(added.isEmpty ? _copy(config) : after, added, const []);
}

/// Remove only handlers whose command exactly matches what dmc writes for
/// that event. Groups, event lists and a `hooks` object emptied by the
/// removal are dropped; everything else is left untouched.
HookConfigPlan planHookUninstall(
  Map<String, Object?> config,
  HookAgent agent,
  String dmcCommand,
) {
  final after = _copy(config);
  final hooks = after['hooks'];
  final removed = <String>[];
  if (hooks is! Map<String, Object?>) {
    return HookConfigPlan(after, const [], removed);
  }
  for (final event in [...hooks.keys]) {
    final groups = hooks[event];
    if (groups is! List<Object?>) continue;
    final command = dmcHookCommand(dmcCommand, agent, event);
    var removedHere = false;
    for (final group in [...groups]) {
      if (group is! Map<String, Object?>) continue;
      final handlers = group['hooks'];
      if (handlers is! List<Object?>) continue;
      final before = handlers.length;
      handlers.removeWhere(
        (handler) => handler is Map && handler['command'] == command,
      );
      if (handlers.length == before) continue;
      removedHere = true;
      if (handlers.isEmpty) groups.remove(group);
    }
    if (!removedHere) continue;
    removed.add(event);
    if (groups.isEmpty) hooks.remove(event);
  }
  // Install adds the "hooks" object when it is missing, so drop it again.
  if (removed.isNotEmpty && hooks.isEmpty) after.remove('hooks');
  return HookConfigPlan(after, const [], removed);
}

/// Per-event installation state of dmc's handlers in [config].
Map<String, bool> hookInstallState(
  Map<String, Object?> config,
  HookAgent agent,
  String dmcCommand,
) {
  final hooks = config['hooks'];
  return {
    for (final event in dmcHookEvents(agent))
      event:
          hooks is Map<String, Object?> &&
          hooks[event] is List<Object?> &&
          _hasCommand(
            hooks[event] as List<Object?>,
            dmcHookCommand(dmcCommand, agent, event),
          ),
  };
}

/// Handlers that call `agent-hook <agent>` but do not match [dmcCommand]
/// exactly, for example from a different dmc install.
List<String> otherDmcHookCommands(
  Map<String, Object?> config,
  HookAgent agent,
  String dmcCommand,
) {
  final hooks = config['hooks'];
  if (hooks is! Map<String, Object?>) return const [];
  final marker = ' agent-hook ${agent.id} ';
  return [
    for (final entry in hooks.entries)
      if (entry.value is List<Object?>)
        for (final group in entry.value as List<Object?>)
          for (final handler in _handlers(group))
            if (handler['command'] is String &&
                (handler['command'] as String).contains(marker) &&
                handler['command'] !=
                    dmcHookCommand(dmcCommand, agent, entry.key))
              handler['command'] as String,
  ];
}

/// Encode [config] in the layout of [original] (single-line or its indent,
/// and whether it ends with a newline), so that uninstall restores a file
/// written by dmc or by the agent to its exact bytes. A new file gets a
/// two-space indent and a trailing newline.
String encodeHookConfig(Map<String, Object?> config, {String original = ''}) {
  final body = original.trimRight();
  final String text;
  if (body.isNotEmpty && !body.contains('\n')) {
    text = jsonEncode(config);
  } else {
    final indent =
        RegExp(r'^([ \t]+)"', multiLine: true).firstMatch(body)?.group(1) ??
        '  ';
    text = JsonEncoder.withIndent(indent).convert(config);
  }
  return original.isEmpty || original.endsWith('\n') ? '$text\n' : text;
}

/// A line diff of [before] and [after], with `-`, `+` and ` ` prefixes.
List<String> lineDiff(String before, String after) {
  final a = before.isEmpty ? <String>[] : const LineSplitter().convert(before);
  final b = const LineSplitter().convert(after);
  if (a.length * b.length > 4000000) {
    return [for (final line in a) '-$line', for (final line in b) '+$line'];
  }
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
  final lines = <String>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      lines.add(' ${a[i]}');
      i++;
      j++;
    } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
      lines.add('-${a[i++]}');
    } else {
      lines.add('+${b[j++]}');
    }
  }
  while (i < a.length) {
    lines.add('-${a[i++]}');
  }
  while (j < b.length) {
    lines.add('+${b[j++]}');
  }
  return lines;
}

/// `dmc hooks install|uninstall|status --agent <agent> [--scope <scope>]`.
///
/// install and uninstall print the exact JSON change and write only when
/// [apply] is true.
Future<int> runHooksCommand({
  required String action,
  required String? agentName,
  String? scopeName,
  bool apply = false,
  String? dmcCommand,
  String? currentDirectory,
  String? homePath,
  String? executable,
}) async {
  if (!{'install', 'uninstall', 'status'}.contains(action)) {
    print('Usage: dmc hooks <install|uninstall|status> --agent <agent>');
    return 2;
  }
  final agent = agentName == null ? null : HookAgent.fromId(agentName);
  if (agent == null) {
    print('[DMC] Error: --agent must be muse-code or claude-code.');
    return 2;
  }
  HookScope scope;
  if (scopeName == null) {
    scope = defaultHookScope(agent);
  } else {
    final match = HookScope.values.where((value) => value.name == scopeName);
    if (match.isEmpty) {
      print('[DMC] Error: --scope must be project, local or user.');
      return 2;
    }
    scope = match.single;
  }

  final home =
      homePath ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'];
  if (home == null) {
    print('[DMC] Error: Cannot find the home directory.');
    return 1;
  }
  final root = findDmcWorkspace(currentDirectory ?? Directory.current.path);
  if (scope != HookScope.user && root == null) {
    print(
      '[DMC] Error: No dmc workspace found here. Run "dmc init" first, or use --scope user.',
    );
    return 1;
  }
  final configPath = hookConfigPath(
    agent,
    scope,
    workspaceRoot: root,
    homePath: home,
  );
  if (configPath == null) {
    print(
      '[DMC] Error: ${agent.displayName} has no ${scope.name} hook scope. Use project or user.',
    );
    return 2;
  }

  var command = dmcCommand?.trim();
  if (command == null || command.isEmpty) {
    final exe = executable ?? Platform.resolvedExecutable;
    final name = p.basenameWithoutExtension(exe).toLowerCase();
    if (name == 'dart' || name == 'dartaotruntime') {
      print(
        '[DMC] Error: dmc is running under the Dart VM, so its executable path is unknown. Pass --dmc-command "<command that runs dmc>".',
      );
      return 2;
    }
    command = shellQuote(p.normalize(p.absolute(exe)));
  }

  final file = File(configPath);
  final exists = file.existsSync();
  final beforeText = exists ? file.readAsStringSync() : '';
  Map<String, Object?> config;
  try {
    final decoded = beforeText.trim().isEmpty
        ? <String, Object?>{}
        : jsonDecode(beforeText);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('The file is not a JSON object.');
    }
    config = decoded;
  } on FormatException catch (error) {
    print(
      '[DMC] Error: $configPath is not valid JSON (${error.message}). Fix it by hand; nothing was changed.',
    );
    return 1;
  }

  print('[DMC] ${agent.displayName} hooks (${scope.name} scope)');
  print('Config: $configPath${exists ? '' : ' (does not exist)'}');
  print('dmc command: $command');
  for (final note in _scopeNotes(agent, scope)) {
    print('Note: $note');
  }

  if (action == 'status') {
    final state = hookInstallState(config, agent, command);
    for (final entry in state.entries) {
      print('${entry.key}: ${entry.value ? 'installed' : 'missing'}');
    }
    for (final other in otherDmcHookCommands(config, agent, command)) {
      print('Other dmc hook (not managed by this command): $other');
    }
    return state.values.every((installed) => installed) ? 0 : 1;
  }

  late final HookConfigPlan plan;
  try {
    plan = action == 'install'
        ? planHookInstall(config, agent, command)
        : planHookUninstall(config, agent, command);
  } on FormatException catch (error) {
    print(
      '[DMC] Error: $configPath has an unexpected shape: ${error.message} Nothing was changed.',
    );
    return 1;
  }
  if (!plan.changed) {
    print(
      action == 'install'
          ? '[DMC] All dmc hooks are already installed. Nothing to change.'
          : '[DMC] No dmc hooks matching this command were found. Nothing to change.',
    );
    return 0;
  }
  for (final event in plan.added) {
    print('+ $event: ${dmcHookCommand(command, agent, event)}');
  }
  for (final event in plan.removed) {
    print('- $event: ${dmcHookCommand(command, agent, event)}');
  }
  // A config left empty by uninstall is one dmc created: remove the file.
  final remove = action == 'uninstall' && plan.after.isEmpty;
  final afterText = remove
      ? ''
      : encodeHookConfig(plan.after, original: beforeText);
  print('--- $configPath');
  print('+++ ${remove ? '/dev/null' : configPath}');
  for (final line in lineDiff(beforeText, afterText)) {
    print(line);
  }
  if (!apply) {
    print('[DMC] Preview only. Run again with --apply to write this change.');
    return 0;
  }
  if (remove) {
    file.deleteSync();
    print('[DMC] Removed $configPath, which held only dmc hooks.');
    return 0;
  }
  file.parent.createSync(recursive: true);
  final temporary = File('$configPath.dmc-tmp');
  temporary.writeAsStringSync(afterText, flush: true);
  temporary.renameSync(configPath);
  print('[DMC] Wrote $configPath.');
  return 0;
}

List<String> _scopeNotes(HookAgent agent, HookScope scope) => [
  if (agent == HookAgent.museCode && scope == HookScope.project)
    'Muse Code runs project hooks only in a trusted workspace and silently skips them otherwise. Trust the folder in interactive muse, or pass --trust-workspace to muse exec.',
  if (agent == HookAgent.museCode && scope == HookScope.user)
    'These hooks run in every Muse Code session; they do nothing outside a dmc workspace.',
  if (agent == HookAgent.claudeCode && scope == HookScope.project)
    '.claude/settings.json is usually committed, and the dmc path is specific to this machine. Prefer --scope local.',
];
