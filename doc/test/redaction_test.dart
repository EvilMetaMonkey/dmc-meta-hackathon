import 'package:dmc_doc/src/redaction.dart';
import 'package:test/test.dart';

void main() {
  final redactor = Redactor();

  // Fake values in the documented shapes, assembled at run time so this file
  // never contains a literal that looks like a live secret.
  String repeat(String unit, int length) =>
      (unit * length).substring(0, length);
  final samples = <String, String>{
    'openai_key': 'sk-proj-${repeat('Ab1', 40)}',
    'anthropic_key': 'sk-ant-api03-${repeat('Xy9', 40)}',
    'aws_access_key': 'AKIA${repeat('Q7', 16)}',
    'github_token': 'ghp_${repeat('a1B', 36)}',
    'slack_token': 'xoxb-${repeat('12', 12)}-${repeat('ab', 16)}',
    'google_api_key': 'AIza${repeat('Sy1_', 35)}',
    'meta_key': 'LLM|1234567890|${repeat('aZ9_', 24)}',
    'baseten_key': '${repeat('aB3', 8)}.${repeat('Zx7', 32)}',
  };

  for (final entry in samples.entries) {
    test('redacts ${entry.key}', () {
      final result = redactor.redact('token: ${entry.value} end');
      expect(result.text, isNot(contains(entry.value)));
      expect(result.text, contains('[REDACTED:'));
      expect(result.count, greaterThanOrEqualTo(1));
    });
  }

  test('fine-grained GitHub tokens and Slack webhooks', () {
    final pat = 'github_pat_${repeat('11AB_', 60)}';
    final hook =
        'https://hooks.slack.com/services/T000/B000/${repeat('xY', 24)}';
    final result = redactor.redact('$pat\n$hook');
    expect(result.text, isNot(contains(pat)));
    expect(result.text, isNot(contains(hook)));
    expect(result.byKind, containsPair('github_token', 1));
    expect(result.byKind, containsPair('slack_webhook', 1));
  });

  test('bearer tokens keep the scheme and drop the token', () {
    final result = redactor.redact(
      'Authorization: Bearer ${repeat('eyJhbGci.', 40)}',
    );
    expect(result.text, 'Authorization: Bearer [REDACTED:bearer_token]');
  });

  test('PEM private-key blocks are removed whole', () {
    final pem =
        '-----BEGIN OPENSSH PRIVATE KEY-----\n${repeat('b3BlbnNzaC1rZXk', 300)}\n-----END OPENSSH PRIVATE KEY-----';
    final result = redactor.redact('before\n$pem\nafter');
    expect(result.text, 'before\n[REDACTED:private_key]\nafter');
    expect(result.count, 1);
  });

  test('credentials in URLs are removed, the host is kept', () {
    final result = redactor.redact(
      'DATABASE at postgres://admin:hunter2@db.example.com:5432/app',
    );
    expect(
      result.text,
      'DATABASE at postgres://[REDACTED:url_credentials]@db.example.com:5432/app',
    );
  });

  test('secret-looking assignments are redacted anywhere', () {
    final result = redactor.redact(
      'export STRIPE_SECRET_KEY=abc123def\nDB_PASSWORD: "hunter2"\nPORT=8080',
    );
    expect(
      result.text,
      'export STRIPE_SECRET_KEY=[REDACTED:assignment]\n'
      'DB_PASSWORD: "[REDACTED:assignment]"\nPORT=8080',
    );
    expect(result.byKind['assignment'], 2);
  });

  test('every assignment in an env-style file is redacted', () {
    final result = redactor.redact(
      'PORT=8080\nDATABASE_HOST=db.internal\n# comment\n',
      fileName: 'config/prod.env',
    );
    expect(
      result.text,
      'PORT=[REDACTED:assignment]\nDATABASE_HOST=[REDACTED:assignment]\n# comment\n',
    );
    expect(result.count, 2);
  });

  test('known secret values are redacted even in unknown formats', () {
    final known = Redactor(knownSecrets: ['opaque-provider-key-0042', 'short']);
    final result = known.redact(
      'the key opaque-provider-key-0042 twice opaque-provider-key-0042; short stays',
    );
    expect(result.text, isNot(contains('opaque-provider-key-0042')));
    expect(result.byKind['known_secret'], 2);
    expect(result.text, contains('short stays'));
  });

  test('never-sent files are recognized by name', () {
    for (final name in [
      '.env',
      '.env.local',
      'config/.env.production',
      'certs/server.pem',
      'tls.key',
      r'C:\Users\me\.ssh\id_rsa',
      'id_rsa.pub',
    ]) {
      expect(Redactor.isNeverSentFile(name), isTrue, reason: name);
    }
    for (final name in [
      'README.md',
      'lib/keys.dart',
      'environment.ts',
      'pem.txt',
    ]) {
      expect(Redactor.isNeverSentFile(name), isFalse, reason: name);
    }
    expect(Redactor.withheldContent('a/.env'), contains('.env is never sent'));
  });

  test('ordinary checkpoint facts are left alone', () {
    const facts =
        'Checkpoint cp_mvqw0quq_ab3fab38ce79b487e3721adb36fb9d84 (closed)\n'
        'sha256 22ffcf1b1c50380e843d35164ae34be31c5daa5094ec89aae8306df9cfb22c8b\n'
        '- lib/src/token_store.dart: modified\n'
        '- docs/API-KEYS.md: created\n'
        'Source: claude-code; agent session bc829b28-8f61-4901-b6ae-349544c6e50c';
    final result = redactor.redact(facts);
    expect(result.text, facts);
    expect(result.count, 0);
  });
}
