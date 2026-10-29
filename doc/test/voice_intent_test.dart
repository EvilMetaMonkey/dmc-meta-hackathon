import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

void main() {
  const heard = 'take me back to before it touched auth';

  group('parseVoiceIntent', () {
    test('accepts the JSON object, also in a ```json fence', () {
      const json =
          '{"command":"restore","text":"before auth","confidence":0.9}';
      for (final text in [json, '```json\n$json\n```']) {
        final intent = parseVoiceIntent(text);
        expect(intent.command, VoiceCommand.restore);
        expect(intent.text, 'before auth');
        expect(intent.confidence, 0.9);
      }
    });

    test('refuses anything else', () {
      for (final text in [
        'restore please',
        '[]',
        '{"command":"rm -rf","text":"","confidence":1}',
        '{"command":"restore","text":3,"confidence":1}',
        '{"command":"restore","text":"x","confidence":2}',
        '{"command":"restore","text":"x"}',
      ]) {
        expect(
          () => parseVoiceIntent(text),
          throwsA(isA<VoiceRouteRefused>()),
          reason: text,
        );
      }
    });
  });

  group('planVoiceAction', () {
    test(
      'restore passes the transcript itself through, not the model text',
      () {
        final action = planVoiceAction(
          const VoiceIntent(VoiceCommand.restore, 'undo everything', 0.9),
          '  $heard ',
        );
        expect(action.runnable, isTrue);
        expect(action.args, ['restore', heard]);
        expect(action.command.alwaysAsk, isTrue);
      },
    );

    test('an unknown command does nothing', () {
      final action = planVoiceAction(
        const VoiceIntent(VoiceCommand.unknown, 'order pizza', 0.99),
        'order a pizza',
      );
      expect(action.runnable, isFalse);
      expect(action.declined, contains('not something Doc can do'));
    });

    test('low confidence does nothing', () {
      final action = planVoiceAction(
        const VoiceIntent(VoiceCommand.restore, heard, 0.59),
        heard,
      );
      expect(action.runnable, isFalse);
      expect(action.declined, contains('confidence 0.59'));
      expect(
        planVoiceAction(
          const VoiceIntent(VoiceCommand.restore, heard, 0.6),
          heard,
        ).runnable,
        isTrue,
      );
    });

    test('an empty transcript does nothing', () {
      expect(
        planVoiceAction(
          const VoiceIntent(VoiceCommand.lessons, '', 1),
          '  ',
        ).runnable,
        isFalse,
      );
    });

    test('the other commands map to Doc command lines', () {
      VoiceAction plan(VoiceCommand command, [String text = '']) =>
          planVoiceAction(VoiceIntent(command, text, 0.9), 'spoken words');
      expect(plan(VoiceCommand.lessons).args, ['lessons']);
      expect(plan(VoiceCommand.status).args, ['status']);
      expect(plan(VoiceCommand.summarizeLatest).args, ['summarize']);
      expect(plan(VoiceCommand.bisect).args, ['bisect']);
      expect(plan(VoiceCommand.bisect).command.alwaysAsk, isTrue);
      expect(plan(VoiceCommand.lessonBrief, 'add a discount').args, [
        'lesson',
        'brief',
        '--task',
        'add a discount',
      ]);
      expect(plan(VoiceCommand.lessonBrief).args.last, 'spoken words');
      expect(plan(VoiceCommand.lessons).command.alwaysAsk, isFalse);
    });
  });

  test('describeDocCommand quotes only what needs it', () {
    expect(
      describeDocCommand(['restore', heard]),
      'doc restore "take me back to before it touched auth"',
    );
    expect(
      describeDocCommand(['bisect', '--test', 'python3 -m unittest']),
      'doc bisect --test "python3 -m unittest"',
    );
  });

  test('the schema only allows known commands', () {
    final schema =
        (voiceRouteResponseFormat()['json_schema'] as Map)['schema'] as Map;
    final command = (schema['properties'] as Map)['command'] as Map;
    expect(command['enum'], [
      'restore',
      'summarize_latest',
      'lesson_brief',
      'lessons',
      'bisect',
      'status',
      'unknown',
    ]);
    expect(voiceCapabilities(), contains('find the turn that broke the tests'));
  });
}
