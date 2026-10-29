import 'dart:convert';

import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

String approaches(List<(String, String, List<String>)> items) => jsonEncode({
  'approaches': [
    for (final (title, plan, files) in items)
      {'title': title, 'plan': plan, 'files_likely': files},
  ],
});

const plans = [
  (
    'Fix the rounding helper',
    'Change round_money in money.py to round to two decimals again and keep its signature.',
    ['money.py'],
  ),
  (
    'Round at the call sites',
    'Leave round_money alone and round the results inside add_tax and subtract_discount instead.',
    ['money.py'],
  ),
  (
    'Use Decimal arithmetic',
    'Replace float math with decimal.Decimal and quantize to cents before returning values.',
    ['money.py', 'nope.py'],
  ),
];

void main() {
  group('parseTimelineApproaches', () {
    test('accepts exactly N clearly different approaches', () {
      final parsed = parseTimelineApproaches(
        approaches(plans),
        3,
        files: {'money.py', 'test_money.py'},
      );
      expect(parsed.map((a) => a.title), [
        'Fix the rounding helper',
        'Round at the call sites',
        'Use Decimal arithmetic',
      ]);
      // Paths not in the base are dropped.
      expect(parsed[2].filesLikely, ['money.py']);
    });

    test('rejects the wrong count, long plans, duplicates and near copies', () {
      void refused(String content, String why) => expect(
        () => parseTimelineApproaches(content, 3),
        throwsA(
          isA<TimelinePlanRefused>().having(
            (e) => e.message,
            'message',
            contains(why),
          ),
        ),
      );
      refused(approaches(plans.take(2).toList()), 'Expected exactly 3');
      refused('not json', 'not a JSON object');
      refused(jsonEncode({'plans': []}), 'no "approaches"');
      refused(
        approaches([
          plans[0],
          plans[1],
          ('Long', List.filled(121, 'word').join(' '), <String>[]),
        ]),
        'at most 120',
      );
      refused(
        approaches([
          plans[0],
          plans[1],
          (
            'fix the ROUNDING helper',
            'Something else entirely here.',
            <String>[],
          ),
        ]),
        'same title',
      );
      refused(
        approaches([
          plans[0],
          plans[1],
          (
            'Another title',
            'Change round_money in money.py to round to two decimals again, keeping its signature.',
            <String>[],
          ),
        ]),
        'not clearly different',
      );
      refused(
        jsonEncode({
          'approaches': [
            {'title': 'x', 'plan': 3, 'files_likely': []},
            ...[
              for (final (t, pl, f) in plans.skip(1))
                {'title': t, 'plan': pl, 'files_likely': f},
            ],
          ],
        }),
        'needs a string',
      );
    });

    test('the schema asks for exactly N', () {
      final schema =
          (timelineApproachesFormat(4)['json_schema'] as Map)['schema'] as Map;
      final list = (schema['properties'] as Map)['approaches'] as Map;
      expect(list['minItems'], 4);
      expect(list['maxItems'], 4);
    });
  });

  test('treeSyncActions copies every export file and deletes the rest', () {
    final actions = treeSyncActions(
      {'state.txt', 'feature1.txt', 'src/new.py'},
      {'state.txt', 'old.txt', 'src/gone.py', '.dmc/x', '.git'},
    );
    expect(actions, const [
      SyncAction('copy', 'feature1.txt'),
      SyncAction('copy', 'src/new.py'),
      SyncAction('copy', 'state.txt'),
      SyncAction('delete', 'old.txt'),
      SyncAction('delete', 'src/gone.py'),
    ]);
  });

  test('parseMuseEvents reads usage and the terminal event', () {
    String line(String type, Map<String, Object?> payload) =>
        jsonEncode({'payload_type': type, 'payload': payload});
    final done = parseMuseEvents([
      'not json',
      line('run.lifecycle.started', {'prompt': 'x'}),
      line('run.usage', {
        'calls': 6,
        'models': [
          {
            'model': 'muse-spark-1.3-contributor',
            'input_tokens': 167108,
            'cached_tokens': 138421,
            'output_tokens': 539,
          },
        ],
      }),
      line('run.terminal.completed', {
        'terminal': 'completed',
        'text': 'Done.',
        'reason': null,
      }),
    ]);
    expect(done.terminal, 'completed');
    expect(done.steps, 6);
    expect(done.model, 'muse-spark-1.3-contributor');
    expect(done.finalText, 'Done.');
    // (28687 × 0.10 + 138421 × 0.002 + 539 × 0.20) / 1e6
    expect(museCostUsd(done), closeTo(0.0032543, 1e-6));

    final limited = parseMuseEvents([
      line('run.terminal.failed', {
        'terminal': 'failed',
        'reason': 'model did not reach a terminal state within 2 step(s)',
      }),
    ]);
    expect(limited.terminal, 'failed');
    expect(limited.stepLimit, isTrue);
    expect(museCostUsd(limited), isNull);
    expect(parseMuseEvents(const []).terminal, isNull);
  });

  test('the cost estimate states its basis', () {
    final estimate = estimateTimelineCost(3, 10);
    expect(
      estimate.contributor,
      closeTo(3 * 10 * (30000 * 0.10 + 600 * 0.20) / 1e6, 1e-9),
    );
    expect(
      estimate.standard,
      closeTo(3 * 10 * (30000 * 1.25 + 600 * 4.25) / 1e6, 1e-9),
    );
  });

  test('parseNumstat', () {
    expect(
      parseNumstat(
        '1\t1\tstate.txt\n-\t-\timage.png\n12\t0\tsrc/new.py\n',
      ).map((f) => f.toJson()),
      [
        {'path': 'state.txt', 'added': 1, 'removed': 1},
        {'path': 'image.png', 'added': null, 'removed': null},
        {'path': 'src/new.py', 'added': 12, 'removed': 0},
      ],
    );
  });

  TimelineRun sampleRun() => TimelineRun(
    id: 'tl-1',
    createdAt: '2026-10-29T00:00:00Z',
    task: 'fix it',
    test: 'make test',
    setup: null,
    links: const [],
    maxSteps: 8,
    timeoutMinutes: 10,
    repo: '/repo',
    workspaceFingerprint: 'fp',
    baseCheckpoint: 'cp_a',
    baseState: 'before',
    baseLabel: 'turn',
    baseCommit: 'abc123',
    brief: null,
    planner: const {'model': 'muse-wonder-1.0'},
    timelines: [
      Timeline(
        k: 1,
        approach: const TimelineApproach('Fix helper', 'plan one', [
          'money.py',
        ]),
        branch: 'doc/timeline/tl-1/1',
        worktree: '/data/tl-1/1',
        status: TimelineStatus.done,
        steps: 5,
        seconds: 72,
        costUsd: 0.0031,
        files: const [TimelineFileChange('money.py', 1, 1)],
        test: const TimelineTest(
          passed: true,
          timedOut: false,
          setupFailed: false,
          seconds: 0.2,
          tail: 'OK',
        ),
      ),
      Timeline(
        k: 2,
        approach: const TimelineApproach('Round callers', 'plan two', []),
        branch: 'doc/timeline/tl-1/2',
        worktree: '/data/tl-1/2',
        status: TimelineStatus.failed,
        reason: 'model did not reach a terminal state within 8 step(s)',
        steps: 8,
        seconds: 130,
        files: const [
          TimelineFileChange('money.py', 4, 0),
          TimelineFileChange('b.png', null, null),
        ],
        test: const TimelineTest(
          passed: false,
          timedOut: false,
          setupFailed: false,
          seconds: 0.3,
          tail: 'line 1\nAssertionError: 20.0 != 19.99\nFAILED (failures=1)',
        ),
      ),
      Timeline(
        k: 3,
        approach: const TimelineApproach('Decimal', 'plan three', []),
        branch: 'doc/timeline/tl-1/3',
        worktree: '/data/tl-1/3',
        status: TimelineStatus.timedOut,
        reason: 'no result within 10 min',
        seconds: 600,
      ),
    ],
    status: 'done',
  );

  test(
    'the run state round-trips through JSON and marks archived timelines',
    () {
      final run = sampleRun();
      final json = jsonDecode(jsonEncode(run.toJson())) as Map;
      final back = TimelineRun.fromJson(json);
      expect(back.toJson(), run.toJson());
      expect(json['command'], 'doc.timelines');
      expect((json['timelines'] as List).map((t) => (t as Map)['pick']), [
        'not picked yet',
        'not picked yet',
        'not picked yet',
      ]);
      back.picked = 1;
      expect(back.toJson()['timelines'], [
        containsPair('pick', 'picked'),
        containsPair('pick', 'archived'),
        containsPair('pick', 'archived'),
      ]);
    },
  );

  test('the comparison shows each timeline side by side', () {
    final lines = timelineComparison(sampleRun());
    expect(lines, [
      '[1] Fix helper',
      '    agent: done, 5 step(s), 1:12, \$0.0031',
      '    files: money.py +1 −1',
      '    tests: PASS (0.2s)',
      '    branch: doc/timeline/tl-1/1  (not picked yet)',
      '[2] Round callers',
      '    agent: step limit, 8 step(s), 2:10 (model did not reach a terminal state within 8 step(s))',
      '    files: money.py +4 −0, b.png (binary)  (total +4 −0)',
      '    tests: FAIL (0.3s)',
      '    branch: doc/timeline/tl-1/2  (not picked yet)',
      '      | line 1',
      '      | AssertionError: 20.0 != 19.99',
      '      | FAILED (failures=1)',
      '[3] Decimal',
      '    agent: timed out, 0 step(s), 10:00 (no result within 10 min)',
      '    files: no changes',
      '    tests: not run',
      '    branch: doc/timeline/tl-1/3  (not picked yet)',
    ]);
  });
}
