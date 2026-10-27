import 'package:path/path.dart' as p;

/// The result of redacting one text.
class RedactionResult {
  final String text;

  /// Redactions by kind, for example `{'openai_key': 1}`.
  final Map<String, int> byKind;

  const RedactionResult(this.text, this.byKind);

  int get count => byKind.values.fold(0, (sum, value) => sum + value);
}

class _Rule {
  final String kind;
  final RegExp pattern;

  /// Builds the replacement from a match; defaults to the whole match.
  final String Function(Match match)? replace;

  const _Rule(this.kind, this.pattern, [this.replace]);
}

String _placeholder(String kind) => '[REDACTED:$kind]';

/// Removes secrets from text before it is sent to a hosted model. Doc runs
/// every hosted prompt through [redact]; nothing bypasses it.
///
/// It recognizes provider key formats, bearer tokens, PEM private keys,
/// credentials in URLs, secret-looking `NAME=value` assignments (every
/// assignment in env-style files), and the exact values of [knownSecrets]
/// (for example, the API keys Doc itself was given).
class Redactor {
  final List<String> _knownSecrets;

  Redactor({Iterable<String> knownSecrets = const []})
    : _knownSecrets = [
        for (final secret in knownSecrets)
          if (secret.trim().length >= 8) secret.trim(),
      ]..sort((a, b) => b.length.compareTo(a.length));

  static final _rules = <_Rule>[
    _Rule(
      'private_key',
      RegExp(
        r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
      ),
    ),
    _Rule(
      'url_credentials',
      RegExp(r'\b([a-zA-Z][a-zA-Z0-9+.-]*://)[^\s/:@]+:[^\s/@]+@'),
      (match) => '${match[1]}${_placeholder('url_credentials')}@',
    ),
    _Rule(
      'bearer_token',
      RegExp(r'\b([Bb]earer\s+)[A-Za-z0-9._~+/=-]{12,}'),
      (match) => '${match[1]}${_placeholder('bearer_token')}',
    ),
    _Rule('anthropic_key', RegExp(r'\bsk-ant-[A-Za-z0-9_-]{20,}')),
    _Rule(
      'openai_key',
      RegExp(r'\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{20,}'),
    ),
    _Rule('aws_access_key', RegExp(r'\b(?:AKIA|ASIA)[0-9A-Z]{16}\b')),
    _Rule('github_token', RegExp(r'\bgithub_pat_[A-Za-z0-9_]{22,}')),
    _Rule('github_token', RegExp(r'\bgh[pousr]_[A-Za-z0-9]{36,}')),
    _Rule('slack_token', RegExp(r'\bxox[abposr]-[A-Za-z0-9-]{10,}')),
    _Rule(
      'slack_webhook',
      RegExp(r'https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+'),
    ),
    _Rule('google_api_key', RegExp(r'\bAIza[0-9A-Za-z_-]{35}')),
    // Meta API keys (LLM|<app id>|<token>) and Baseten keys (<8>.<32>).
    _Rule('meta_key', RegExp(r'\bLLM\|[0-9]{6,}\|[A-Za-z0-9_-]{16,}')),
    _Rule('baseten_key', RegExp(r'\b[A-Za-z0-9]{8}\.[A-Za-z0-9]{32}\b')),
  ];

  /// `NAME=value` (or `export NAME=value`, `NAME: value`) where NAME looks
  /// secret.
  static final _secretAssignment = RegExp(
    r'''^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD|PWD|CREDENTIALS?|AUTH|PRIVATE)[A-Za-z0-9_]*\s*[=:]\s*)(["']?)([^\s"'#][^"'\r\n]*?)\2\s*$''',
    caseSensitive: false,
    multiLine: true,
  );

  /// Any `NAME=value` line, for env-style files.
  static final _anyAssignment = RegExp(
    r'''^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*)(["']?)([^\s"'#][^"'\r\n]*?)\2\s*$''',
    multiLine: true,
  );

  /// Redact [text]. Pass [fileName] when the text is a file's content, so
  /// env-style files have every assignment redacted.
  RedactionResult redact(String text, {String? fileName}) {
    final counts = <String, int>{};
    void count(String kind) => counts[kind] = (counts[kind] ?? 0) + 1;

    var result = text;
    for (final secret in _knownSecrets) {
      if (!result.contains(secret)) continue;
      final parts = result.split(secret);
      for (var i = 1; i < parts.length; i++) {
        count('known_secret');
      }
      result = parts.join(_placeholder('known_secret'));
    }
    for (final rule in _rules) {
      result = result.replaceAllMapped(rule.pattern, (match) {
        // Never re-redact a placeholder.
        if (match[0]!.contains('[REDACTED:')) return match[0]!;
        count(rule.kind);
        return rule.replace?.call(match) ?? _placeholder(rule.kind);
      });
    }
    final assignment = fileName != null && isEnvStyleFile(fileName)
        ? _anyAssignment
        : _secretAssignment;
    result = result.replaceAllMapped(assignment, (match) {
      final value = match[3]!;
      if (value.startsWith('[REDACTED:')) return match[0]!;
      count('assignment');
      return '${match[1]}${match[2]}${_placeholder('assignment')}${match[2]}';
    });
    return RedactionResult(result, counts);
  }

  /// Files whose content is never sent to a hosted model, only their name:
  /// `.env*`, `*.pem`, `*.key`, `id_rsa*`.
  static bool isNeverSentFile(String path) {
    final name = p.basename(path.replaceAll('\\', '/'));
    final lower = name.toLowerCase();
    return lower.startsWith('.env') ||
        lower.endsWith('.pem') ||
        lower.endsWith('.key') ||
        lower.startsWith('id_rsa');
  }

  /// Env-style files, where every `NAME=value` line is redacted.
  static bool isEnvStyleFile(String path) {
    final lower = p.basename(path.replaceAll('\\', '/')).toLowerCase();
    return lower.startsWith('.env') ||
        lower.endsWith('.env') ||
        lower == '.envrc' ||
        lower.endsWith('.properties');
  }

  /// The text Doc sends in place of a never-sent file's content.
  static String withheldContent(String path) =>
      '[content withheld: ${p.basename(path)} is never sent to a hosted model]';
}
