import 'package:dmc_doc/src/config.dart';
import 'package:dmc_doc/src/model_client.dart';
import 'package:test/test.dart';

import 'support/fake_provider.dart';

void main() {
  late List<Duration> sleeps;
  late List<String> logs;

  ChatClient client({int maxRetries = 3}) => ChatClient(
    maxRetries: maxRetries,
    sleep: (delay) async => sleeps.add(delay),
    log: logs.add,
  );

  /// A default provider with its request style, pointed at [baseUrl].
  ProviderConfig provider(String id, String baseUrl) =>
      ProviderConfig.fromJson(id, {
        ...DocConfig.defaults().providers[id]!.toJson(),
        'baseUrl': baseUrl,
        'timeoutSeconds': 5,
      });

  Map<String, Object?> body(ProviderConfig provider) => chatRequestBody(
    provider: provider,
    model: 'fake-model',
    messages: const [ChatMessage('user', 'hi')],
    maxTokens: 32,
  );

  setUp(() {
    sleeps = [];
    logs = [];
  });

  test(
    'a success returns message.content and drops reasoning_content',
    () async {
      final fake = await FakeProvider.start([
        FakeReply.chat(
          'ok',
          reasoning: 'secret chain of thought',
          prompt: 20,
          completion: 5,
        ),
      ]);
      addTearDown(fake.close);
      final baseten = provider('baseten', fake.baseUrl);
      final result = await client().complete(
        provider: baseten,
        body: body(baseten),
        apiKey: 'test-key-123456',
      );
      expect(result.content, 'ok');
      expect(result.content, isNot(contains('chain of thought')));
      expect(result.promptTokens, 20);
      expect(result.completionTokens, 5);
      expect(result.attempts, 1);
      final request = fake.requests.single;
      expect(request.path, '/v1/chat/completions');
      expect(request.authorization, 'Bearer test-key-123456');
      expect(request.body!['max_tokens'], 32);
      expect(request.body!['reasoning_effort'], 'low');
    },
  );

  test('429 then success retries with backoff', () async {
    final fake = await FakeProvider.start([
      const FakeReply(429, {'error': 'slow down'}),
      FakeReply.chat('ok'),
    ]);
    addTearDown(fake.close);
    final meta = provider('meta', fake.baseUrl);
    final result = await client().complete(
      provider: meta,
      body: body(meta),
      apiKey: 'k-12345678',
    );
    expect(result.content, 'ok');
    expect(result.attempts, 2);
    expect(fake.requests, hasLength(2));
    expect(sleeps, hasLength(1));
    expect(sleeps.single.inMilliseconds, inInclusiveRange(500, 1000));
    expect(logs.single, contains('retry 1 of 3'));
  });

  test('5xx exhausts retries; Retry-After is honoured up to 30 s', () async {
    final fake = await FakeProvider.start([
      const FakeReply(503, {'error': 'down'}, headers: {'retry-after': '120'}),
    ]);
    addTearDown(fake.close);
    final meta = provider('meta', fake.baseUrl);
    final failure = await client(maxRetries: 2)
        .complete(provider: meta, body: body(meta), apiKey: 'k-12345678')
        .then<ModelCallException?>(
          (_) => null,
          onError: (Object e) => e as ModelCallException,
        );
    expect(failure!.kind, ModelCallFailure.http);
    expect(failure.statusCode, 503);
    expect(failure.attempts, 3);
    expect(failure.message, contains('after 3 attempts'));
    expect(fake.requests, hasLength(3));
    expect(sleeps, everyElement(const Duration(seconds: 30)));
  });

  test('a 4xx other than 429 is not retried', () async {
    final fake = await FakeProvider.start([
      const FakeReply(401, {'error': 'bad key'}),
    ]);
    addTearDown(fake.close);
    final meta = provider('meta', fake.baseUrl);
    await expectLater(
      client().complete(provider: meta, body: body(meta), apiKey: 'k-12345678'),
      throwsA(
        isA<ModelCallException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.retryable, 'retryable', isFalse),
      ),
    );
    expect(fake.requests, hasLength(1));
  });

  test('an unreachable server fails at once and plainly', () async {
    final local = provider('local', await closedBaseUrl());
    await expectLater(
      client().complete(provider: local, body: body(local), apiKey: null),
      throwsA(
        isA<ModelCallException>()
            .having((e) => e.kind, 'kind', ModelCallFailure.unreachable)
            .having(
              (e) => e.message,
              'message',
              contains('no server answered'),
            ),
      ),
    );
    expect(sleeps, isEmpty);
  });

  test('the API key never appears in an error message', () async {
    const key = 'super-secret-key-value-42';
    final fake = await FakeProvider.start([
      const FakeReply(400, {'error': 'invalid key super-secret-key-value-42'}),
    ]);
    addTearDown(fake.close);
    final meta = provider('meta', fake.baseUrl);
    final failure = await client()
        .complete(provider: meta, body: body(meta), apiKey: key)
        .then<ModelCallException?>(
          (_) => null,
          onError: (Object e) => e as ModelCallException,
        );
    expect(failure!.message, isNot(contains(key)));
    expect(failure.message, contains('[key]'));
  });

  test('meta requests follow Muse Spark parameter rules', () {
    final meta = provider('meta', 'http://unused/v1');
    final request = chatRequestBody(
      provider: meta,
      model: 'muse-spark-1.3',
      messages: const [ChatMessage('user', 'hi')],
      maxTokens: 100,
      reasoningEffort: 'none',
    );
    expect(request['reasoning_effort'], 'low');
    expect(request['max_completion_tokens'], 100);
    for (final forbidden in [
      'max_tokens',
      'stop',
      'n',
      'logit_bias',
      'frequency_penalty',
      'presence_penalty',
      'temperature',
    ]) {
      expect(request.containsKey(forbidden), isFalse, reason: forbidden);
    }
    final local = chatRequestBody(
      provider: provider('local', 'http://unused/v1'),
      model: 'muse-glimmer',
      messages: const [ChatMessage('user', 'hi')],
      maxTokens: 100,
    );
    expect(local.containsKey('reasoning_effort'), isFalse);
    expect(local['max_tokens'], 100);
  });

  test('listModels returns the sorted IDs', () async {
    final fake = await FakeProvider.start([
      const FakeReply(200, {
        'data': [
          {'id': 'muse-wonder-1.0'},
          {'id': 'muse-spark-1.3'},
        ],
      }),
    ]);
    addTearDown(fake.close);
    final ids = await client().listModels(
      provider('meta', fake.baseUrl),
      'k-12345678',
    );
    expect(ids, ['muse-spark-1.3', 'muse-wonder-1.0']);
    expect(fake.requests.single.method, 'GET');
    expect(fake.requests.single.path, '/v1/models');
  });

  test('Muse Glimmer requests use Meta\'s sampling and reasoning strength', () {
    final body = chatRequestBody(
      provider: provider('modal', 'http://unused/v1'),
      model: 'muse-glimmer',
      messages: const [
        ChatMessage('system', 'You summarize.'),
        ChatMessage('user', 'hi'),
      ],
      maxTokens: 300,
    );
    final messages = (body['messages'] as List).cast<Map>();
    expect(
      messages.first['content'],
      'Reasoning strength: low.\nYou summarize.',
    );
    expect(messages, hasLength(2));
    expect(body['temperature'], 1.0);
    expect(body['top_p'], 0.95);
    expect(body['top_k'], 64);
    expect(body['max_tokens'], 300);
    expect(body.containsKey('reasoning_effort'), isFalse);
    final noSystem = chatRequestBody(
      provider: provider('modal', 'http://unused/v1'),
      model: 'muse-glimmer',
      messages: const [ChatMessage('user', 'hi')],
      maxTokens: 10,
    );
    expect(
      ((noSystem['messages'] as List).first as Map)['content'],
      'Reasoning strength: low.',
    );
  });

  test('reasoning text left in an answer is stripped', () async {
    expect(
      stripReasoning(
        '<|start|>assistant to=self<|message|>thinking<|eom|>'
        '<|start|>assistant to=user<|message|>The answer.<|end|>',
      ),
      'The answer.',
    );
    expect(stripReasoning('<think>hmm</think>Plain'), 'Plain');
    final fake = await FakeProvider.start([
      FakeReply.chat('<think>private</think>Visible answer'),
    ]);
    addTearDown(fake.close);
    final modal = provider('modal', fake.baseUrl);
    final result = await client().complete(
      provider: modal,
      body: body(modal),
      apiKey: 'modal-key-1234',
    );
    expect(result.content, 'Visible answer');
  });

  test('a slow first call prints the wake notice once', () async {
    final fake = await FakeProvider.start([
      FakeReply.chat('awake'),
    ], delay: const Duration(milliseconds: 300));
    addTearDown(fake.close);
    final modal = provider('modal', fake.baseUrl);
    final result = await ChatClient(
      log: logs.add,
      wakeAfter: const Duration(milliseconds: 50),
    ).complete(provider: modal, body: body(modal), apiKey: 'modal-key-1234');
    expect(result.content, 'awake');
    expect(logs, [
      'Waking Muse Glimmer on Modal (can take a couple of minutes)…',
    ]);
  });

  test('defaults route roles as specified', () {
    final config = DocConfig.defaults();
    expect(config.roles['summary']!.provider, 'baseten');
    expect(config.roles['summary']!.model, basetenSparkOpenModel);
    expect(config.roles['summary']!.fallbackProvider, 'fireworks');
    expect(modalSummaryRole.provider, 'modal');
    expect(modalSummaryRole.fallbackProvider, 'baseten');
    expect(config.roles['workhorse']!.fallbackProvider, 'fireworks');
    expect(config.roles['workhorse']!.fallbackModel, fireworksSparkOpenModel);
    expect(config.providers['fireworks']!.budgetUsd, 100);
    expect(config.providers['modal']!.billing, ProviderBilling.gpuTime);
    expect(
      config.providers['modal']!.timeout.inSeconds,
      greaterThanOrEqualTo(300),
    );
    expect(config.providers['modal']!.label, 'modal (your private deployment)');
    expect(config.roles['workhorse']!.model, basetenSparkOpenModel);
    expect(config.roles['restore']!.fallbackProvider, 'baseten');
    expect(config.roles['planner']!.model, metaWonderModel);
    expect(config.roles['voice']!.chat, isFalse);
    expect(config.providers['meta']!.budgetUsd, 150);
    expect(config.providers['baseten']!.budgetUsd, 100);
    expect(config.providers['local']!.hosted, isFalse);
  });
}
