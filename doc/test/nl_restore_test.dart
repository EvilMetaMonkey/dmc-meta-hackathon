import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

NlFileState file(String hash) => NlFileState('file', hash, 420);
const absent = NlFileState('absent', null, null);

/// A candidate that changed [files] (path -> (before, after)).
RestoreCandidate candidate(
  String id,
  int at, {
  Map<String, (NlFileState, NlFileState)> files = const {},
  String? label,
  bool undone = false,
}) => RestoreCandidate(
  id: id,
  source: 'claude-code',
  agent: 'claude-code',
  session: 's1',
  label: label ?? 'turn $id',
  createdAt: at,
  closedAt: at + 1,
  alreadyUndone: undone,
  files: [
    for (final entry in files.entries)
      NlCandidateFile(
        path: entry.key,
        change: entry.value.$1.absent
            ? 'created'
            : entry.value.$2.absent
            ? 'deleted'
            : 'modified',
        before: entry.value.$1,
        after: entry.value.$2,
      ),
  ],
);

NlRestoreAnswer answer(
  String id, {
  NlRestoreMode mode = NlRestoreMode.goBackBefore,
  double confidence = 0.9,
  List<String> alternatives = const [],
}) => NlRestoreAnswer(
  mode: mode,
  checkpointId: id,
  confidence: confidence,
  reason: 'because',
  alternatives: alternatives,
);

/// dmc's preview envelope: [actions] paths, [conflicts] paths.
NlStepPreview preview(
  RestoreCandidate step, {
  List<String> actions = const [],
  List<String> conflicts = const [],
}) => NlStepPreview(step, {
  'ok': conflicts.isEmpty,
  'errors': [
    for (final path in conflicts)
      {'code': 'workspace_drift', 'message': 'drift', 'path': path},
  ],
  'data': {
    'actions': [
      for (final path in actions) {'path': path},
    ],
    'conflicts': [
      for (final path in conflicts)
        {'code': 'workspace_drift', 'message': 'drift', 'path': path},
    ],
    'dataErrors': [],
    'skipped': [],
  },
});

void main() {
  // Newest first, as Doc offers them.
  final c3 = candidate(
    'cp_c',
    300,
    files: {'notes.md': (file('n1'), file('n2'))},
  );
  final c2 = candidate(
    'cp_b',
    200,
    files: {
      'auth.py': (file('a1'), file('a2')),
      'notes.md': (absent, file('n1')),
    },
  );
  final c1 = candidate(
    'cp_a',
    100,
    files: {'app.py': (file('p1'), file('p2'))},
  );
  final candidates = [c3, c2, c1];

  group('parseNlRestoreAnswer', () {
    test('accepts the JSON object, also in a ```json fence', () {
      const json =
          '{"mode":"undo_turn","checkpoint_id":"cp_b","confidence":0.8,"reason":"r","alternatives":["cp_a"]}';
      for (final text in [json, '```json\n$json\n```']) {
        final parsed = parseNlRestoreAnswer(text);
        expect(parsed.mode, NlRestoreMode.undoTurn);
        expect(parsed.checkpointId, 'cp_b');
        expect(parsed.confidence, 0.8);
        expect(parsed.alternatives, ['cp_a']);
      }
    });

    test('refuses anything else', () {
      for (final text in [
        'take cp_b',
        '[]',
        '{"mode":"delete_all","checkpoint_id":"cp_b","confidence":1,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","checkpoint_id":"cp_b","confidence":1.5,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","checkpoint_id":7,"confidence":1,"reason":"r","alternatives":[]}',
        '{"mode":"undo_turn","checkpoint_id":"cp_b","confidence":1,"reason":"r","alternatives":[3]}',
      ]) {
        expect(
          () => parseNlRestoreAnswer(text),
          throwsA(isA<NlRestoreRefused>()),
          reason: text,
        );
      }
    });
  });

  group('planNaturalRestore', () {
    test('an id that is not a candidate is refused', () {
      expect(
        () => planNaturalRestore(answer('cp_zzz'), candidates),
        throwsA(
          isA<NlRestoreRefused>().having(
            (e) => e.message,
            'message',
            contains('not one of the 3 candidate'),
          ),
        ),
      );
      expect(
        () => planNaturalRestore(
          answer('cp_b', alternatives: ['cp_zzz']),
          candidates,
        ),
        throwsA(isA<NlRestoreRefused>()),
      );
    });

    test('go_back_before undoes the target and every later one, newest '
        'first', () {
      final plan = planNaturalRestore(answer('cp_b'), candidates);
      expect([for (final s in plan.steps) s.id], ['cp_c', 'cp_b']);
      expect(plan.oldestStep!.id, 'cp_b');
      expect(plan.needsChoice, isFalse);
    });

    test('undo_turn undoes one checkpoint', () {
      final plan = planNaturalRestore(
        answer('cp_b', mode: NlRestoreMode.undoTurn),
        candidates,
      );
      expect([for (final s in plan.steps) s.id], ['cp_b']);
    });

    test('low confidence or alternatives need a choice', () {
      expect(
        planNaturalRestore(
          answer('cp_b', confidence: 0.59),
          candidates,
        ).needsChoice,
        isTrue,
      );
      final withAlternatives = planNaturalRestore(
        answer('cp_b', alternatives: ['cp_b', 'cp_a', 'cp_a']),
        candidates,
      );
      expect(withAlternatives.needsChoice, isTrue);
      expect(
        [for (final c in withAlternatives.choices) c.id],
        ['cp_b', 'cp_a'],
      );
      expect(
        planNaturalRestore(
          answer('cp_b', confidence: 0.6),
          candidates,
        ).needsChoice,
        isFalse,
      );
    });

    test('already undone checkpoints are not restored again', () {
      final undone = candidate('cp_c', 300, undone: true);
      final plan = planNaturalRestore(answer('cp_b'), [undone, c2, c1]);
      expect([for (final s in plan.steps) s.id], ['cp_b']);
      expect([for (final s in plan.alreadyUndone) s.id], ['cp_c']);
    });
  });

  group('combineStepPreviews', () {
    test('a file a newer step puts back is chained, not a conflict', () {
      // dmc previews cp_b against the working copy, where notes.md is
      // still cp_c's after state, so it reports drift on notes.md.
      final combined = combineStepPreviews([
        preview(c3, actions: ['notes.md']),
        preview(c2, actions: ['auth.py'], conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isTrue, reason: '${combined.conflicts}');
      final byPath = {for (final f in combined.files) f.path: f};
      expect(byPath.keys, ['auth.py', 'notes.md']);
      expect(byPath['notes.md']!.currentStep, 0);
      expect(byPath['notes.md']!.finalStep, 1);
      expect(byPath['notes.md']!.result.absent, isTrue);
      expect(byPath['notes.md']!.description, 'delete it');
      expect(
        byPath['auth.py']!.description,
        'put back the version from before step 2',
      );
    });

    test('a file changed between turns breaks the chain', () {
      final edited = candidate(
        'cp_b',
        200,
        files: {'notes.md': (absent, file('n-other'))},
      );
      final combined = combineStepPreviews([
        preview(c3, actions: ['notes.md']),
        preview(edited, conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isFalse);
      expect(combined.conflicts.single.code, 'chain_mismatch');
    });

    test('dmc conflicts on files no newer step touches stand', () {
      final combined = combineStepPreviews([
        preview(c3, conflicts: ['notes.md']),
      ]);
      expect(combined.canApply, isFalse);
      expect(combined.conflicts.single.code, 'workspace_drift');
      expect(combined.conflicts.single.path, 'notes.md');
    });

    test('steps that cancel out are no net change', () {
      final created = candidate(
        'cp_x',
        100,
        files: {'tmp.txt': (absent, file('t'))},
      );
      final deleted = candidate(
        'cp_y',
        200,
        files: {'tmp.txt': (file('t'), absent)},
      );
      final combined = combineStepPreviews([
        preview(deleted, actions: ['tmp.txt']),
        preview(created, conflicts: ['tmp.txt']),
      ]);
      expect(combined.canApply, isTrue);
      expect(combined.files.single.netChange, isFalse);
      expect(combined.changing, isEmpty);
    });
  });

  test('labels dmc cut are marked as truncated', () {
    final cut = candidate('cp_t', 1, label: 'Rewrite the auth module to…');
    expect(cut.labelTruncated, isTrue);
    expect(cut.displayLabel, endsWith('(truncated by dmc)'));
    expect(cut.modelLabel, contains(truncatedLabelMarker));
    expect(cut.toJson()['labelTruncated'], isTrue);
    final message = nlRestoreUserMessage('before auth', [cut, c1]);
    expect(
      message,
      contains('Rewrite the auth module to $truncatedLabelMarker'),
    );
    expect(message, contains('label: turn cp_a\n'));
  });

  test('the schema only allows candidate ids', () {
    final schema =
        (nlRestoreResponseFormat(candidates)['json_schema'] as Map)['schema']
            as Map;
    final properties = schema['properties'] as Map;
    expect((properties['checkpoint_id'] as Map)['enum'], [
      'cp_c',
      'cp_b',
      'cp_a',
    ]);
  });

  test('lineCounts', () {
    expect(lineCounts('a\nb\nc\n', 'a\nB\nc\nd\n'), (added: 2, removed: 1));
    expect(lineCounts(null, 'x\ny\n'), (added: 2, removed: 0));
    expect(lineCounts('x\n', null), (added: 0, removed: 1));
  });

  test('recentClosedCheckpoints keeps the newest closed ones', () {
    final items = [
      {'id': 'cp_1', 'status': 'closed', 'createdAt': 1},
      {'id': 'cp_2', 'status': 'invalid', 'createdAt': 2},
      {'id': 'cp_3', 'status': 'closed', 'createdAt': 3},
      {'id': 'cp_4', 'status': 'closed', 'createdAt': 4},
    ];
    expect(
      [for (final i in recentClosedCheckpoints(items, 2)) i['id']],
      ['cp_4', 'cp_3'],
    );
  });
}
