import 'dart:convert';

/// "Hey Doc": from a transcript to one validated Doc command. The model
/// (workhorse role) only classifies the request; the command line is built
/// here, deterministically, and nothing runs without the user's yes.

/// Below this confidence Doc does nothing but say what it heard.
const double voiceMinConfidence = 0.6;

/// What a spoken request can ask for.
enum VoiceCommand {
  restore('restore', 'go back to an earlier state (natural-language restore)'),
  summarizeLatest('summarize_latest', 'summarize the latest checkpoint'),
  lessonBrief('lesson_brief', 'brief you on lessons for a task'),
  lessons('lessons', 'list the lesson library'),
  bisect('bisect', 'find the turn that broke the tests'),
  status('status', 'show the latest checkpoints'),
  unknown('unknown', '');

  final String wire;
  final String help;
  const VoiceCommand(this.wire, this.help);

  static VoiceCommand? parse(Object? value) {
    for (final command in values) {
      if (command.wire == value) return command;
    }
    return null;
  }

  /// Restore and bisect always ask "Run it?", even with `--yes`.
  bool get alwaysAsk =>
      this == VoiceCommand.restore || this == VoiceCommand.bisect;
}

/// What Doc can do by voice, for the "I'm not sure" answer.
String voiceCapabilities() => [
  'I can:',
  for (final command in VoiceCommand.values)
    if (command != VoiceCommand.unknown) '  - ${command.help}',
].join('\n');

const String voiceRouteSystemPrompt =
    'You route one spoken request to a command of Doc, the companion to '
    'dmc, a rollback safety net for AI coding agents. Commands: "restore" '
    '(go back to or undo earlier agent work, for example "take me back to '
    'before it touched auth"), "summarize_latest" (summarize the latest '
    'checkpoint or agent turn), "lesson_brief" (brief on lessons before a '
    'task; put the task in text), "lessons" (list lessons), "bisect" (find '
    'which turn broke the tests), "status" (what happened recently), and '
    '"unknown" for anything else. Answer with only a JSON object: '
    '{"command": one of those, "text": the request in the user\'s own words '
    '(the task for lesson_brief), "confidence": 0 to 1}. Speech '
    'recognition can mishear words; lower the confidence when unsure. Never '
    'invent a command.';

/// The `response_format` schema for the routing answer.
Map<String, Object?> voiceRouteResponseFormat() => {
  'type': 'json_schema',
  'json_schema': {
    'name': 'voice_route',
    'strict': true,
    'schema': {
      'type': 'object',
      'additionalProperties': false,
      'required': ['command', 'text', 'confidence'],
      'properties': {
        'command': {
          'type': 'string',
          'enum': [for (final c in VoiceCommand.values) c.wire],
        },
        'text': {'type': 'string'},
        'confidence': {'type': 'number'},
      },
    },
  },
};

/// The routing model's answer, parsed.
class VoiceIntent {
  final VoiceCommand command;
  final String text;
  final double confidence;

  const VoiceIntent(this.command, this.text, this.confidence);

  Map<String, Object?> toJson() => {
    'command': command.wire,
    'text': text,
    'confidence': confidence,
  };
}

class VoiceRouteRefused implements Exception {
  final String message;
  const VoiceRouteRefused(this.message);

  @override
  String toString() => message;
}

/// Strict parsing: one JSON object (a ```json fence is tolerated) with a
/// known command, a string text and a confidence from 0 to 1.
VoiceIntent parseVoiceIntent(String content) {
  var text = content.trim();
  final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
  if (fence != null) text = fence[1]!.trim();
  final Object? json;
  try {
    json = jsonDecode(text);
  } on FormatException {
    throw const VoiceRouteRefused('The answer was not a JSON object.');
  }
  if (json is! Map) {
    throw const VoiceRouteRefused('The answer was not a JSON object.');
  }
  final command = VoiceCommand.parse(json['command']);
  if (command == null) {
    throw VoiceRouteRefused(
      '"command" must be one of ${VoiceCommand.values.map((c) => c.wire).join(', ')}, not ${jsonEncode(json['command'])}.',
    );
  }
  final said = json['text'];
  if (said is! String) {
    throw const VoiceRouteRefused('"text" must be a string.');
  }
  final confidence = json['confidence'];
  if (confidence is! num || confidence < 0 || confidence > 1) {
    throw const VoiceRouteRefused('"confidence" must be a number from 0 to 1.');
  }
  return VoiceIntent(command, said.trim(), confidence.toDouble());
}

/// One Doc command to offer, or nothing.
class VoiceAction {
  final VoiceCommand command;

  /// The arguments for `doc`, when they are known now; `summarize_latest`
  /// and `bisect` fill theirs in when run.
  final List<String> args;

  /// Why nothing will run (unknown or low confidence), else null.
  final String? declined;

  const VoiceAction(this.command, this.args, {this.declined});

  bool get runnable => declined == null;

  Map<String, Object?> toJson() => {
    'command': command.wire,
    'args': args,
    'declined': declined,
  };
}

/// Validate [intent] for [transcript] into an action. Pure: the transcript
/// itself (not the model's rewording) is what natural-language restore
/// gets, so the model cannot change the request.
VoiceAction planVoiceAction(VoiceIntent intent, String transcript) {
  final heard = transcript.trim();
  if (heard.isEmpty) {
    return const VoiceAction(
      VoiceCommand.unknown,
      [],
      declined: 'Nothing was heard.',
    );
  }
  if (intent.command == VoiceCommand.unknown) {
    return const VoiceAction(
      VoiceCommand.unknown,
      [],
      declined: 'That is not something Doc can do yet.',
    );
  }
  if (intent.confidence < voiceMinConfidence) {
    return VoiceAction(
      intent.command,
      const [],
      declined:
          'Not sure enough what you meant (confidence ${intent.confidence.toStringAsFixed(2)}).',
    );
  }
  return switch (intent.command) {
    VoiceCommand.restore => VoiceAction(intent.command, ['restore', heard]),
    VoiceCommand.summarizeLatest => VoiceAction(intent.command, ['summarize']),
    VoiceCommand.lessonBrief => VoiceAction(intent.command, [
      'lesson',
      'brief',
      '--task',
      intent.text.isEmpty ? heard : intent.text,
    ]),
    VoiceCommand.lessons => VoiceAction(intent.command, ['lessons']),
    VoiceCommand.bisect => VoiceAction(intent.command, ['bisect']),
    VoiceCommand.status => VoiceAction(intent.command, ['status']),
    VoiceCommand.unknown => throw StateError('handled above'),
  };
}

/// How a command line looks to the user: `doc restore "take me back"`.
String describeDocCommand(List<String> args) => [
  'doc',
  for (final arg in args)
    RegExp(r'^[A-Za-z0-9_./=:-]+$').hasMatch(arg) ? arg : jsonEncode(arg),
].join(' ');
