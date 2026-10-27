import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const dmcCommand = '/opt/dmc/bin/dmc';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('dmc_hook_installer_');
    root = Directory(p.join(sandbox.path, 'project'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
    await initDmc(basePath: root.path);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  Future<({int code, List<String> output})> hooks(
    String action,
    String agent, {
    String? scope,
    bool apply = false,
    String? command = dmcCommand,
    String? executable,
    String? cwd,
  }) async {
    final output = <String>[];
    final code = await runZoned(
      () => runHooksCommand(
        action: action,
        agentName: agent,
        scopeName: scope,
        apply: apply,
        dmcCommand: command,
        currentDirectory: cwd ?? root.path,
        homePath: home.path,
        executable: executable,
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, message) => output.add(message),
      ),
    );
    return (code: code, output: output);
  }

  File claudeLocal() =>
      File(p.join(root.path, '.claude', 'settings.local.json'));
  File museUser() =>
      File(p.join(home.path, '.config', 'muse', 'settings.json'));

  Map<String, Object?> read(File file) =>
      jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

  final foreign = {
    'permissions': {
      'allow': ['Bash(ls:*)'],
    },
    'hooks': {
      'Stop': [
        {
          'matcher': '*',
          'hooks': [
            {'type': 'command', 'command': 'echo foreign-stop'},
            // Same agent-hook call, but a different dmc install.
            {
              'type': 'command',
              'command': '/other/dmc agent-hook claude-code Stop',
            },
          ],
        },
      ],
      'PreToolUse': [
        {
          'matcher': 'Bash',
          'hooks': [
            {'type': 'command', 'command': 'echo foreign-pretool'},
          ],
        },
      ],
    },
  };

  test('install previews by default and writes only with --apply', () async {
    final preview = await hooks('install', 'claude-code');
    expect(preview.code, 0);
    expect(claudeLocal().existsSync(), isFalse);
    expect(
      preview.output,
      contains('+ Stop: $dmcCommand agent-hook claude-code Stop'),
    );
    expect(
      preview.output,
      anyElement(
        allOf(
          startsWith('+ '),
          endsWith(
            '"command": "$dmcCommand agent-hook claude-code UserPromptSubmit",',
          ),
        ),
      ),
    );
    expect(preview.output.last, contains('--apply'));

    final applied = await hooks('install', 'claude-code', apply: true);
    expect(applied.code, 0);
    final config = read(claudeLocal());
    final hooksConfig = config['hooks'] as Map<String, Object?>;
    expect(hooksConfig.keys, [
      'UserPromptSubmit',
      'Stop',
      'StopFailure',
      'SessionEnd',
    ]);
    expect(hooksConfig['Stop'], [
      {
        'matcher': '*',
        'hooks': [
          {
            'type': 'command',
            'command': '$dmcCommand agent-hook claude-code Stop',
            'timeout': 60,
          },
        ],
      },
    ]);
  });

  test('install is idempotent and merges into foreign config', () async {
    claudeLocal()
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(foreign));
    expect((await hooks('install', 'claude-code', apply: true)).code, 0);
    final first = claudeLocal().readAsStringSync();
    final again = await hooks('install', 'claude-code', apply: true);
    expect(again.code, 0);
    expect(again.output.last, contains('already installed'));
    expect(claudeLocal().readAsStringSync(), first);

    final config = read(claudeLocal());
    expect(config['permissions'], foreign['permissions']);
    final hooksConfig = config['hooks'] as Map<String, Object?>;
    expect(hooksConfig['PreToolUse'], (foreign['hooks'] as Map)['PreToolUse']);
    final stop = hooksConfig['Stop'] as List;
    expect(stop, hasLength(2));
    expect(stop.first, ((foreign['hooks'] as Map)['Stop'] as List).first);

    final status = await hooks('status', 'claude-code');
    expect(status.code, 0);
    expect(status.output, contains('Stop: installed'));
    expect(
      status.output,
      contains(
        'Other dmc hook (not managed by this command): /other/dmc agent-hook claude-code Stop',
      ),
    );
  });

  test('uninstall removes only exact dmc entries', () async {
    claudeLocal()
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(foreign));
    expect((await hooks('install', 'claude-code', apply: true)).code, 0);
    expect(claudeLocal().readAsStringSync(), isNot(contains('\n')));

    final preview = await hooks('uninstall', 'claude-code');
    expect(preview.code, 0);
    expect(
      preview.output,
      contains('- Stop: $dmcCommand agent-hook claude-code Stop'),
    );
    expect(read(claudeLocal()), isNot(foreign));

    expect((await hooks('uninstall', 'claude-code', apply: true)).code, 0);
    expect(claudeLocal().readAsStringSync(), jsonEncode(foreign));

    final nothing = await hooks('uninstall', 'claude-code', apply: true);
    expect(nothing.code, 0);
    expect(nothing.output.last, contains('Nothing to change'));
    expect(read(claudeLocal()), foreign);

    final status = await hooks('status', 'claude-code');
    expect(status.code, 1);
    expect(status.output, contains('Stop: missing'));
  });

  test(
    'uninstall restores exact bytes or removes a file dmc created',
    () async {
      // Muse Code writes settings with a two-space indent and no final newline.
      const original =
          '{\n  "schema_version": 1,\n  "provider": "meta",\n  "model": "m"\n}';
      museUser()
        ..createSync(recursive: true)
        ..writeAsStringSync(original);
      expect((await hooks('install', 'muse-code', apply: true)).code, 0);
      expect(read(museUser()), contains('hooks'));
      expect(museUser().readAsStringSync(), isNot(endsWith('\n')));
      expect((await hooks('uninstall', 'muse-code', apply: true)).code, 0);
      expect(museUser().readAsStringSync(), original);

      expect((await hooks('install', 'claude-code', apply: true)).code, 0);
      final preview = await hooks('uninstall', 'claude-code');
      expect(preview.output, contains('+++ /dev/null'));
      expect(claudeLocal().existsSync(), isTrue);
      final removed = await hooks('uninstall', 'claude-code', apply: true);
      expect(removed.code, 0);
      expect(removed.output.last, contains('Removed'));
      expect(claudeLocal().existsSync(), isFalse);
    },
  );

  test('Muse Code defaults to user settings with an async Interrupt', () async {
    final result = await hooks('install', 'muse-code', apply: true);
    expect(result.code, 0, reason: result.output.join('\n'));
    final hooksConfig = read(museUser())['hooks'] as Map<String, Object?>;
    expect(hooksConfig.keys, [
      'UserPromptSubmit',
      'Stop',
      'StopFailure',
      'Interrupt',
      'SessionEnd',
    ]);
    final interrupt =
        ((hooksConfig['Interrupt'] as List).single as Map)['hooks'] as List;
    expect(interrupt.single, {
      'type': 'command',
      'command': '$dmcCommand agent-hook muse-code Interrupt',
      'timeout': 60,
      'async': true,
    });
    final stop = ((hooksConfig['Stop'] as List).single as Map)['hooks'] as List;
    expect((stop.single as Map).containsKey('async'), isFalse);
  });

  test('Muse Code project scope writes .muse/hooks.json', () async {
    final result = await hooks(
      'install',
      'muse-code',
      scope: 'project',
      apply: true,
    );
    expect(result.code, 0);
    expect(
      result.output,
      contains(startsWith('Note: Muse Code runs project hooks')),
    );
    expect(File(p.join(root.path, '.muse', 'hooks.json')).existsSync(), isTrue);
    expect(museUser().existsSync(), isFalse);
  });

  test(
    'unsupported scopes, bad JSON and missing workspaces fail safely',
    () async {
      expect((await hooks('install', 'muse-code', scope: 'local')).code, 2);

      claudeLocal()
        ..createSync(recursive: true)
        ..writeAsStringSync('{ not json');
      final invalid = await hooks('install', 'claude-code', apply: true);
      expect(invalid.code, 1);
      expect(claudeLocal().readAsStringSync(), '{ not json');

      claudeLocal().writeAsStringSync(jsonEncode({'hooks': []}));
      final wrongShape = await hooks('install', 'claude-code', apply: true);
      expect(wrongShape.code, 1);
      expect(read(claudeLocal()), {'hooks': []});

      final outside = Directory(p.join(sandbox.path, 'outside'))..createSync();
      expect(
        (await hooks('install', 'claude-code', cwd: outside.path)).code,
        1,
      );
      expect((await hooks('install', 'codex')).code, 2);
    },
  );

  test(
    'the default command is this executable, quoted for the shell',
    () async {
      final underVm = await hooks(
        'install',
        'claude-code',
        command: null,
        executable: '/usr/lib/dart/bin/dart',
      );
      expect(underVm.code, 2);
      expect(underVm.output.single, contains('--dmc-command'));

      final spaced = p.join(sandbox.path, 'My Tools', 'dmc');
      final result = await hooks(
        'install',
        'claude-code',
        command: null,
        executable: spaced,
        apply: true,
      );
      expect(result.code, 0);
      expect(
        hookInstallState(
          read(claudeLocal()),
          HookAgent.claudeCode,
          "'$spaced'",
        ).values,
        everyElement(isTrue),
      );
      expect(shellQuote("it's"), "'it'\\''s'");
    },
  );
}
