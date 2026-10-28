import 'package:dmc_doc/src/lessons.dart';
import 'package:test/test.dart';

Lesson lesson(
  String id,
  List<String> files, {
  DateTime? created,
  String status = 'approved',
}) => Lesson(
  id: id,
  title: 'Lesson $id',
  files: files,
  created: created ?? DateTime.utc(2026, 10, 27),
  source: const LessonSource(checkpoint: 'cp_1'),
  status: status,
  body: '## What was tried\nx',
);

void main() {
  test('front matter round trips, including awkward titles', () {
    final original = Lesson(
      id: '2026-10-27-keep-greet-s-signature-1a2b',
      title: 'Keep greet()\'s signature: callers "depend" on it — ünïcode',
      files: const ['app.py', 'src/lib/util.ts'],
      created: DateTime.utc(2026, 10, 27, 22, 10, 5),
      source: const LessonSource(
        checkpoint: 'cp_mvqw0quq_ab3f',
        agent: 'claude-code',
        session: 'bc829b28-8f61',
      ),
      status: 'approved',
      body:
          '## What was tried\nRenamed the parameter.\n\n## Why it failed\nCallers broke.',
    );
    final text = original.toMarkdown();
    expect(
      text,
      startsWith('---\nid: "2026-10-27-keep-greet-s-signature-1a2b"\n'),
    );
    expect(text, contains('files:\n  - "app.py"\n  - "src/lib/util.ts"\n'));
    expect(text, contains('source:\n  checkpoint: "cp_mvqw0quq_ab3f"\n'));
    final parsed = Lesson.parse(text);
    expect(parsed.id, original.id);
    expect(parsed.title, original.title);
    expect(parsed.files, original.files);
    expect(parsed.created, original.created);
    expect(parsed.source.checkpoint, 'cp_mvqw0quq_ab3f');
    expect(parsed.source.agent, 'claude-code');
    expect(parsed.source.session, 'bc829b28-8f61');
    expect(parsed.status, 'approved');
    expect(parsed.body, original.body);
    expect(parsed.toMarkdown(), text);
  });

  test('hand-edited plain YAML values parse too', () {
    final parsed = Lesson.parse(
      '---\nid: abc-1\ntitle: Plain title\nfiles:\n  - a.txt\n'
      "created: 2026-10-27T00:00:00Z\nsource:\n  checkpoint: cp_x\nstatus: 'draft'\n---\nBody\n",
    );
    expect(parsed.title, 'Plain title');
    expect(parsed.status, 'draft');
    expect(parsed.files, ['a.txt']);
    expect(() => Lesson.parse('no front matter'), throwsFormatException);
    expect(() => Lesson.parse('---\nid: a\n---\nbody'), throwsFormatException);
  });

  test('approval problems are reported', () {
    expect(lesson('ok-1', ['a.txt']).problems(), isEmpty);
    final bad = Lesson(
      id: 'Bad Id',
      title: ' ',
      files: const ['../escape.txt', '/abs.txt'],
      created: DateTime.utc(2026),
      source: const LessonSource(checkpoint: 'cp'),
      status: 'draft',
      body: '',
    );
    expect(bad.problems(), hasLength(5));
    expect(lesson('no-files', const []).problems(), ['files is empty']);
  });

  group('matching rule', () {
    const workspace = [
      'app.py',
      'src/util.ts',
      'web/index.ts',
      'api/index.ts',
      'docs/guide.md',
    ];

    test('exact paths and unique basenames resolve; ambiguous ones do not', () {
      expect(
        candidateFiles(
          'Fix `src/util.ts`, then app.py. Also touch index.ts and ./docs/guide.md.',
          workspace,
        ),
        {'src/util.ts', 'app.py', 'docs/guide.md'},
      );
      expect(candidateFiles('look at util.ts', workspace), {'src/util.ts'});
      expect(candidateFiles('nothing named here', workspace), isEmpty);
      expect(candidateFiles('e.g. missing.py', workspace), isEmpty);
      expect(
        candidateFiles('anything', workspace, extraFiles: ['./api/index.ts']),
        {'api/index.ts'},
      );
      expect(candidateFiles(r'Windows path src\util.ts', workspace), {
        'src/util.ts',
      });
    });

    test(
      'score is file overlap; ties go to the newest; top 3; drafts never match',
      () {
        final lessons = [
          lesson('one-file-old', ['app.py'], created: DateTime.utc(2026, 1, 1)),
          lesson('one-file-new', ['app.py'], created: DateTime.utc(2026, 9, 1)),
          lesson('two-files', [
            'app.py',
            'src/util.ts',
          ], created: DateTime.utc(2025, 1, 1)),
          lesson('one-file-mid', [
            'src/util.ts',
          ], created: DateTime.utc(2026, 5, 1)),
          lesson('unrelated', ['docs/guide.md']),
          lesson('a-draft', ['app.py', 'src/util.ts'], status: 'draft'),
        ];
        final matches = matchLessons(lessons, {'app.py', 'src/util.ts'});
        expect(matches.map((match) => match.lesson.id), [
          'two-files',
          'one-file-new',
          'one-file-mid',
        ]);
        expect(matches.first.score, 2);
        expect(matches.first.matchedFiles, ['app.py', 'src/util.ts']);
        expect(matchLessons(lessons, const {}), isEmpty);
        expect(matchLessons(lessons, {'web/index.ts'}), isEmpty);
      },
    );
  });

  test('the first prompt is the brief, a blank line, then the task', () {
    const brief = 'Before you start: keep greet() stable.';
    const task = 'Add a farewell function to app.py';
    expect(
      composeFirstPrompt(task: task, brief: brief, accepted: true),
      '$brief\n\n$task',
    );
    expect(composeFirstPrompt(task: task, brief: brief, accepted: false), task);
    expect(composeFirstPrompt(task: task, brief: null, accepted: true), task);
  });

  test('new ids are dated, slugged and lowercase', () {
    final id = LessonStore.newId(
      'Don\'t rename greet()!',
      DateTime.utc(2026, 10, 27),
    );
    expect(id, matches(RegExp(r'^2026-10-27-don-t-rename-greet-[0-9a-f]{4}$')));
    expect(lesson(id, ['a']).problems(), isEmpty);
  });
}
