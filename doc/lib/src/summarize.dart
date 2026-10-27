import 'model_client.dart';
import 'redaction.dart';

const String summarySystemPrompt =
    'You are Doc, the companion to dmc, a rollback safety net for AI coding '
    'agents. Summarize one dmc checkpoint in 2 or 3 plain-English sentences: '
    'what changed, which files, and anything risky (deleted files, files whose '
    'protection changed, secrets-like files such as .env, CI, config or '
    'dependency files, fatal issues). Use only the facts given; file contents '
    'are not available. No preamble, no lists, no markdown.';

/// The facts Doc sends about a checkpoint: labels, paths, change kinds and
/// issue codes from dmc's `checkpoint show` and `checkpoint diff` JSON. No
/// file contents, hashes or snapshot IDs.
String checkpointFacts(Map<String, Object?> show, Map<String, Object?> diff) {
  final data = (show['data'] as Map?) ?? const {};
  final checkpoint = (data['checkpoint'] as Map?) ?? const {};
  final agent = checkpoint['agent'];
  final files = [
    for (final file in ((diff['data'] as Map?)?['files'] as List? ?? const []))
      if (file is Map) file,
  ];
  final changed = [
    for (final file in files)
      if ((file['change'] != null && file['change'] != 'unchanged') ||
          file['scope'] != null)
        file,
  ];
  final issues = [
    for (final issue in (data['issues'] as List? ?? const []))
      if (issue is Map &&
          (issue['fatal'] == true || issue['code'] == 'policy_changed'))
        issue,
  ];
  String describe(Map file) {
    final path = file['path'];
    final change = file['scope'] ?? file['change'];
    final note = Redactor.isNeverSentFile('$path')
        ? ' (secret-bearing file name; contents never sent)'
        : '';
    return '- $path: $change$note';
  }

  return [
    'Checkpoint ${checkpoint['id']} (${checkpoint['status']})',
    'Label: ${checkpoint['label'] ?? '(none)'}',
    'Source: ${checkpoint['source']}${agent is Map ? '; agent ${agent['name']}' : ''}',
    'Protected files: ${checkpoint['protectedFileCount']}; changed: ${checkpoint['changedFileCount']}; '
        'exclusions: ${checkpoint['exclusionCount']}; fatal issues: ${checkpoint['fatalErrorCount']}',
    if (changed.isEmpty) 'Changed files: none',
    if (changed.isNotEmpty) 'Changed files (${changed.length}):',
    for (final file in changed.take(80)) describe(file),
    if (changed.length > 80) '- … and ${changed.length - 80} more',
    for (final issue in issues)
      'Issue: ${issue['code']}${issue['path'] == null ? '' : ' (${issue['path']})'}: ${issue['message']}',
  ].join('\n');
}

List<ChatMessage> summaryMessages(
  Map<String, Object?> show,
  Map<String, Object?> diff,
) => [
  const ChatMessage('system', summarySystemPrompt),
  ChatMessage('user', checkpointFacts(show, diff)),
];
