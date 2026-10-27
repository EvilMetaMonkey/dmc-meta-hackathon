import 'dart:io';

import 'package:dmc_doc/src/config.dart';
import 'package:dmc_doc/src/model_client.dart';
import 'package:dmc_doc/src/model_router.dart';
import 'package:dmc_doc/src/usage.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/fake_provider.dart';

void main() {
  late Directory sandbox;
  late UsageStore usage;
  late List<String> logs;
  const metaKey = 'meta-test-key-000001';
  const basetenKey = 'baseten-test-key-0002';
  const env = {'MODEL_API_KEY': metaKey, 'BASETEN_API_KEY': basetenKey};

  DocConfig config({
    required String meta,
    required String baseten,
    required String local,
    double metaBudget = 150,
  }) {
    final defaults = DocConfig.defaults();
    ProviderConfig at(String id, String url, {double? budget}) {
      final base = defaults.providers[id]!;
      return ProviderConfig(
        id: id,
        baseUrl: url,
        keyEnv: base.keyEnv,
        defaultModel: base.defaultModel,
        hosted: base.hosted,
        prices: base.prices,
        budgetUsd: budget ?? base.budgetUsd,
        timeout: const Duration(seconds: 5),
      );
    }

    return DocConfig(
      providers: {
        'meta': at('meta', meta, budget: metaBudget),
        'baseten': at('baseten', baseten),
        'local': at('local', local),
      },
      roles: defaults.roles,
    );
  }

  ModelRouter router(
    DocConfig config, {
    bool localOnly = false,
    Map<String, String> roleProviders = const {},
  }) => ModelRouter(
    config: config,
    environment: env,
    usage: usage,
    client: ChatClient(maxRetries: 2, sleep: (_) async {}),
    localOnly: localOnly,
    roleProviders: roleProviders,
    log: logs.add,
  );

  const prompt = [ChatMessage('user', 'Summarize this checkpoint.')];

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('doc_router_');
    usage = UsageStore(File(p.join(sandbox.path, 'usage.json')));
    logs = [];
  });

  tearDown(() => sandbox.deleteSync(recursive: true));

  test('meta 5xx after retries falls back to baseten, logged', () async {
    final meta = await FakeProvider.start([
      const FakeReply(503, {'error': 'down'}),
    ]);
    final baseten = await FakeProvider.start([
      FakeReply.chat(
        'fallback answer',
        reasoning: 'hidden',
        prompt: 1000,
        completion: 200,
      ),
    ]);
    addTearDown(meta.close);
    addTearDown(baseten.close);
    final result = await router(
      config(
        meta: meta.baseUrl,
        baseten: baseten.baseUrl,
        local: await closedBaseUrl(),
      ),
    ).call('restore', prompt);
    expect(meta.requests, hasLength(3));
    expect(baseten.requests.single.authorization, 'Bearer $basetenKey');
    expect(baseten.requests.single.body!['model'], basetenSparkOpenModel);
    expect(result.result.content, 'fallback answer');
    expect(result.fellBackFrom, 'meta');
    expect(logs.where((line) => line.startsWith('FALLBACK')), hasLength(1));
    expect(logs.last, contains('role "restore" failed on meta'));
    // Cost uses the fallback model's price: 1000 * 1.25 + 200 * 4.25 per 1e6.
    expect(result.costUsd, closeTo(0.0021, 1e-9));
    expect(usage.forProvider('baseten').promptTokens, 1000);
    expect(usage.forProvider('meta').calls, 0);
  });

  test('a rejected key is not a reason to fall back', () async {
    final meta = await FakeProvider.start([
      const FakeReply(401, {'error': 'no'}),
    ]);
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(meta.close);
    addTearDown(baseten.close);
    await expectLater(
      router(
        config(
          meta: meta.baseUrl,
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
        ),
      ).call('restore', prompt),
      throwsA(
        isA<ModelCallException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(baseten.requests, isEmpty);
    expect(logs.where((line) => line.startsWith('FALLBACK')), isEmpty);
  });

  test('a used-up budget blocks the call before anything is sent', () async {
    final meta = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(meta.close);
    usage.record('meta', 1, 1, 0.50);
    final routed = router(
      config(
        meta: meta.baseUrl,
        baseten: await closedBaseUrl(),
        local: await closedBaseUrl(),
        metaBudget: 0.50,
      ),
    );
    await expectLater(
      routed.call('planner', prompt),
      throwsA(
        isA<ModelCallException>()
            .having((e) => e.kind, 'kind', ModelCallFailure.budgetExceeded)
            .having((e) => e.message, 'message', contains('budget of \$0.50')),
      ),
    );
    expect(meta.requests, isEmpty);
  });

  test('--local routes every role locally and refuses hosted calls', () async {
    final local = await FakeProvider.start([FakeReply.chat('local answer')]);
    final meta = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(local.close);
    addTearDown(meta.close);
    final settings = config(
      meta: meta.baseUrl,
      baseten: await closedBaseUrl(),
      local: local.baseUrl,
    );
    final routed = router(
      settings,
      localOnly: true,
      roleProviders: const {'summary': 'baseten'},
    );
    for (final role in settings.roles.keys) {
      expect(routed.resolve(role).provider.id, 'local', reason: role);
    }
    final result = await routed.call('restore', prompt);
    expect(result.result.content, 'local answer');
    expect(local.requests.single.authorization, isNull);
    await expectLater(
      routed.callProvider(settings.providers['meta']!, metaSparkModel, prompt),
      throwsA(
        isA<ModelCallException>().having(
          (e) => e.kind,
          'kind',
          ModelCallFailure.refused,
        ),
      ),
    );
    expect(meta.requests, isEmpty);
  });

  test('a local failure never falls back to a hosted provider', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(baseten.close);
    await expectLater(
      router(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
        ),
      ).call('summary', prompt),
      throwsA(
        isA<ModelCallException>().having(
          (e) => e.kind,
          'kind',
          ModelCallFailure.unreachable,
        ),
      ),
    );
    expect(baseten.requests, isEmpty);
  });

  test('a one-run role override uses the provider\'s default model', () async {
    final baseten = await FakeProvider.start([
      FakeReply.chat('override answer'),
    ]);
    addTearDown(baseten.close);
    final result = await router(
      config(
        meta: await closedBaseUrl(),
        baseten: baseten.baseUrl,
        local: await closedBaseUrl(),
      ),
      roleProviders: const {'summary': 'baseten'},
    ).call('summary', prompt);
    expect(result.result.provider, 'baseten');
    expect(baseten.requests.single.body!['model'], basetenSparkOpenModel);
  });

  test('a hosted model without a price is refused', () async {
    final meta = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(meta.close);
    final settings = config(
      meta: meta.baseUrl,
      baseten: await closedBaseUrl(),
      local: await closedBaseUrl(),
    );
    await expectLater(
      router(
        settings,
      ).callProvider(settings.providers['meta']!, 'muse-unknown', prompt),
      throwsA(
        isA<ModelCallException>()
            .having((e) => e.kind, 'kind', ModelCallFailure.refused)
            .having((e) => e.message, 'message', contains('no price')),
      ),
    );
    expect(meta.requests, isEmpty);
  });

  test('prompts are redacted before they are sent', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('ok')]);
    addTearDown(baseten.close);
    final secret = 'sk-${'Abc123' * 6}';
    final result =
        await router(
          config(
            meta: await closedBaseUrl(),
            baseten: baseten.baseUrl,
            local: await closedBaseUrl(),
          ),
        ).call('workhorse', [
          ChatMessage('user', 'my key is $secret and the meta key is $metaKey'),
        ]);
    final sent =
        (baseten.requests.single.body!['messages'] as List).single as Map;
    expect(sent['content'], isNot(contains(secret)));
    expect(sent['content'], isNot(contains(metaKey)));
    expect(result.redactionCount, 2);
  });
}
