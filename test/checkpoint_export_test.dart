import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dmc/dmc.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late Directory home;

  File file(String relative) =>
      File(p.joinAll([root.path, ...relative.split('/')]));

  void write(String relative, String contents) => file(relative)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);

  CheckpointService service() =>
      CheckpointService(basePath: root.path, homePath: home.path);

  /// Every file below [directory] outside the vault: POSIX relative path →
  /// contents.
  Map<String, String> tree(Directory directory) => {
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    ))
      if (entity is File &&
          p.split(p.relative(entity.path, from: directory.path)).first !=
              '.dmc')
        p.split(p.relative(entity.path, from: directory.path)).join('/'): entity
            .readAsStringSync(),
  };

  Future<CommandResult> export(
    String id,
    String to, {
    String state = 'after',
  }) => exportCheckpoint(id, to: to, state: state, basePath: root.path);

  /// A closed checkpoint with a modified, a deleted, a created, an unchanged
  /// and an executable file.
  Future<String> turn() async {
    write('modified.txt', 'before');
    write('deleted.txt', 'deleted at close');
    write('unchanged.txt', 'same');
    write('nested dir/ü.txt', 'nested');
    write('run.sh', '#!/bin/sh\necho hi\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', file('run.sh').path]);
    }
    final begin = await service().begin(source: 'test');
    expect(begin.exitCode, 0, reason: begin.encode());
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    write('modified.txt', 'after');
    file('deleted.txt').deleteSync();
    write('created.txt', 'created');
    final close = await service().close(id);
    expect(close.exitCode, 0, reason: close.encode());
    return id;
  }

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('dmc_export_');
    root = Directory(p.join(sandbox.path, 'export ws ü'))..createSync();
    home = Directory(p.join(sandbox.path, 'home'))..createSync();
    await initDmc(basePath: root.path);
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('exports the before and after manifests with modes', () async {
    final id = await turn();
    final workspaceBefore = tree(root);

    final afterDir = p.join(sandbox.path, 'out after');
    final after = await export(id, afterDir);
    expect(after.exitCode, 0, reason: after.encode());
    expect(tree(Directory(afterDir)), {
      'modified.txt': 'after',
      'created.txt': 'created',
      'unchanged.txt': 'same',
      'nested dir/ü.txt': 'nested',
      'run.sh': '#!/bin/sh\necho hi\n',
    });
    expect(after.data['checkpointId'], id);
    expect(after.data['state'], 'after');
    expect(after.data['directory'], afterDir);
    expect(after.data['fileCount'], 5);
    expect(
      after.data['totalBytes'],
      'after'.length +
          'created'.length +
          'same'.length +
          'nested'.length +
          '#!/bin/sh\necho hi\n'.length,
    );

    final beforeDir = p.join(sandbox.path, 'out before');
    final before = await export(id, beforeDir, state: 'before');
    expect(before.exitCode, 0, reason: before.encode());
    expect(tree(Directory(beforeDir)), {
      'modified.txt': 'before',
      'deleted.txt': 'deleted at close',
      'unchanged.txt': 'same',
      'nested dir/ü.txt': 'nested',
      'run.sh': '#!/bin/sh\necho hi\n',
    });
    expect(before.data['manifestSha256'], isNot(after.data['manifestSha256']));

    if (!Platform.isWindows) {
      for (final directory in [afterDir, beforeDir]) {
        expect(
          File(p.join(directory, 'run.sh')).statSync().mode & 0x1ff,
          0x1ed, // 0755
        );
        expect(
          File(p.join(directory, 'unchanged.txt')).statSync().mode &
              0x49, // no execute bits
          0,
        );
      }
    }

    // The same state exported again has the same manifest hash.
    final again = await export(id, p.join(sandbox.path, 'again'));
    expect(again.data['manifestSha256'], after.data['manifestSha256']);
    // The working copy was never touched.
    expect(tree(root), workspaceBefore);
  });

  test('an existing empty directory is accepted', () async {
    final id = await turn();
    final target = Directory(p.join(sandbox.path, 'empty'))..createSync();
    final result = await export(id, target.path);
    expect(result.exitCode, 0, reason: result.encode());
    expect(tree(target), contains('created.txt'));
  });

  test('a corrupted snapshot fails and leaves nothing behind', () async {
    final id = await turn();
    final view = await service().show(id);
    final created = (view.data['files'] as List).cast<Map>().singleWhere(
      (entry) => entry['path'] == 'created.txt',
    );
    final database = DmcDatabase(DmcPaths(basePath: root.path).dbPath)
      ..initialize();
    final row = database.getSnapshotById(
      (created['after'] as Map)['snapshotId'] as int,
    )!;
    database.close();
    File(
      p.join(DmcPaths(basePath: root.path).snapshotsPath, row.snapshotPath),
    ).writeAsStringSync('tampered');
    final before = sandbox.listSync().map((entity) => entity.path).toSet();

    final target = p.join(sandbox.path, 'broken');
    final result = await export(id, target);
    expect(result.exitCode, 5, reason: result.encode());
    expect(result.errors.single.code, 'snapshot_unavailable');
    expect(FileSystemEntity.typeSync(target), FileSystemEntityType.notFound);
    expect(sandbox.listSync().map((entity) => entity.path).toSet(), before);
  });

  test('unsafe, non-empty and non-directory targets are refused', () async {
    final id = await turn();
    final inside = await export(id, p.join(root.path, 'export'));
    expect(inside.exitCode, 2);
    expect(inside.errors.single.code, 'unsafe_export_target');
    expect(Directory(p.join(root.path, 'export')).existsSync(), isFalse);

    final containing = await export(id, sandbox.path);
    expect(containing.errors.single.code, 'unsafe_export_target');
    final itself = await export(id, root.path);
    expect(itself.errors.single.code, 'unsafe_export_target');

    final busy = Directory(p.join(sandbox.path, 'busy'))..createSync();
    File(p.join(busy.path, 'keep.txt')).writeAsStringSync('keep');
    final nonEmpty = await export(id, busy.path);
    expect(nonEmpty.exitCode, 4);
    expect(nonEmpty.errors.single.code, 'export_target_not_empty');
    expect(tree(busy), {'keep.txt': 'keep'});

    final plain = File(p.join(sandbox.path, 'plain.txt'))
      ..writeAsStringSync('x');
    expect(
      (await export(id, plain.path)).errors.single.code,
      'export_target_not_directory',
    );

    final orphan = await export(id, p.join(sandbox.path, 'no', 'such', 'dir'));
    expect(orphan.errors.single.code, 'export_parent_missing');

    if (!Platform.isWindows) {
      final real = Directory(p.join(sandbox.path, 'real'))..createSync();
      final link = Link(p.join(sandbox.path, 'link'))..createSync(real.path);
      final linked = await export(id, link.path);
      expect(linked.errors.single.code, 'export_target_not_directory');
      expect(real.listSync(), isEmpty);
      // A link that points into the workspace is caught by the canonical check.
      final intoWorkspace = Link(p.join(sandbox.path, 'into'))
        ..createSync(root.path);
      final sneaky = await export(id, p.join(intoWorkspace.path, 'out'));
      expect(sneaky.errors.single.code, 'unsafe_export_target');
      expect(Directory(p.join(root.path, 'out')).existsSync(), isFalse);
    }

    expect(
      (await export(
        id,
        p.join(sandbox.path, 'x'),
        state: 'middle',
      )).errors.single.code,
      'invalid_state',
    );
  });

  test('an open checkpoint exports its before state only', () async {
    write('a.txt', 'a');
    final begin = await service().begin(source: 'test');
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    final after = await export(id, p.join(sandbox.path, 'after'));
    expect(after.exitCode, 3);
    expect(after.errors.single.code, 'checkpoint_not_exportable');
    final before = await export(
      id,
      p.join(sandbox.path, 'before'),
      state: 'before',
    );
    expect(before.exitCode, 0, reason: before.encode());
    expect(tree(Directory(p.join(sandbox.path, 'before'))), {'a.txt': 'a'});
    expect(
      (await export(
        'cp_missing',
        p.join(sandbox.path, 'm'),
      )).errors.single.code,
      'checkpoint_not_found',
    );
  });

  test('left_scope and entered_scope files follow each manifest', () async {
    write('.dmcignore', 'generated/\n');
    write('generated/model.txt', 'generated');
    write('secret.txt', 'secret before');
    final begin = await service().begin(source: 'test');
    final id = (begin.data['checkpoint'] as Map)['id'] as String;
    write('.dmcignore', 'secret.txt\n');
    write('secret.txt', 'secret after');
    final close = await service().close(id);
    expect(close.exitCode, 0, reason: close.encode());

    final before = await export(
      id,
      p.join(sandbox.path, 'before'),
      state: 'before',
    );
    expect(before.exitCode, 0, reason: before.encode());
    // left_scope keeps its before state; entered_scope has none.
    expect(tree(Directory(p.join(sandbox.path, 'before'))), {
      '.dmcignore': 'generated/\n',
      'secret.txt': 'secret before',
    });
    final after = await export(id, p.join(sandbox.path, 'after'));
    expect(after.exitCode, 0, reason: after.encode());
    // entered_scope has an after state; left_scope has none.
    expect(tree(Directory(p.join(sandbox.path, 'after'))), {
      '.dmcignore': 'secret.txt\n',
      'generated/model.txt': 'generated',
    });
  });

  test(
    'the CLI prints one JSON envelope and capabilities list export',
    () async {
      final id = await turn();
      final previous = Directory.current;
      final output = <String>[];
      Directory.current = root;
      try {
        await runZoned(
          () async {
            await runCli(['capabilities', '--json']);
            await runCli([
              'checkpoint',
              'export',
              id,
              '--to',
              p.join(sandbox.path, 'cli'),
              '--json',
              '--schema-version',
              '1',
            ]);
          },
          zoneSpecification: ZoneSpecification(
            print: (_, _, _, message) => output.add(message),
          ),
        );
      } finally {
        Directory.current = previous;
      }
      expect(output, hasLength(2));
      final capabilities = jsonDecode(output.first) as Map;
      expect(
        (capabilities['data'] as Map)['commands'],
        contains('checkpoint.export'),
      );
      expect(
        ((capabilities['data'] as Map)['features'] as Map)['checkpointExport'],
        isTrue,
      );
      final exported = jsonDecode(output.last) as Map;
      expect(exported['ok'], isTrue);
      expect(exported['command'], 'checkpoint.export');
      expect((exported['data'] as Map).keys, [
        'checkpointId',
        'state',
        'directory',
        'fileCount',
        'totalBytes',
        'manifestSha256',
      ]);
    },
  );
}
