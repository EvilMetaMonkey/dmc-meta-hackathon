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
  const env = {
    'MODEL_API_KEY': metaKey,
    'BASETEN_API_KEY': basetenKey,
    'FIREWORKS_API_KEY': 'fireworks-test-key-03',
    'MODAL_GLIMMER_KEY': 'modal-test-key-000004',
  };

  /// The default providers, each pointed at a fake (or closed) URL.
  /// [modal] null leaves Modal unconfigured, as on a machine without it.
  DocConfig config({
    required String meta,
    required String baseten,
    required String local,
    String fireworks = 'http://127.0.0.1:9/v1',
    String? modal,
    bool summaryOnModal = false,
    double metaBudget = 150,
  }) {
    final defaults = DocConfig.defaults();
    ProviderConfig at(String id, String url, {double? budget}) =>
        ProviderConfig.fromJson(id, {
          ...defaults.providers[id]!.toJson(),
          'baseUrl': url,
          'budgetUsd': budget ?? defaults.providers[id]!.budgetUsd,
          'timeoutSeconds': 5,
        });

    return DocConfig(
      providers: {
        'meta': at('meta', meta, budget: metaBudget),
        'baseten': at('baseten', baseten),
        'fireworks': at('fireworks', fireworks),
        'modal': at('modal', modal ?? ''),
        'local': at('local', local),
      },
      // Summary on Modal, falling back to Baseten (now also the default).
      roles: summaryOnModal
          ? {...defaults.roles, 'summary': modalSummaryRole}
          : defaults.roles,
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
        roleProviders: const {'summary': 'local'},
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

  test(
    'an answer cut off by the token limit is explained and billed',
    () async {
      final baseten = await FakeProvider.start([
        const FakeReply(200, {
          'choices': [
            {
              'message': {
                'role': 'assistant',
                'content': null,
                'reasoning_content': 'hmm',
              },
              'finish_reason': 'length',
            },
          ],
          'usage': {'prompt_tokens': 100, 'completion_tokens': 32},
        }),
      ]);
      final meta = await FakeProvider.start([FakeReply.chat('never')]);
      addTearDown(baseten.close);
      addTearDown(meta.close);
      await expectLater(
        router(
          config(
            meta: meta.baseUrl,
            baseten: baseten.baseUrl,
            local: await closedBaseUrl(),
          ),
        ).call('workhorse', prompt, maxTokens: 32),
        throwsA(
          isA<ModelCallException>()
              .having((e) => e.kind, 'kind', ModelCallFailure.truncated)
              .having(
                (e) => e.message,
                'message',
                contains('used all 32 completion tokens'),
              ),
        ),
      );
      expect(usage.forProvider('baseten').completionTokens, 32);
      expect(meta.requests, isEmpty);
    },
  );

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

  test(
    'summary uses Muse Glimmer on Modal, unpriced, without a budget',
    () async {
      final modal = await FakeProvider.start([
        FakeReply.chat('glimmer summary', prompt: 400, completion: 90),
      ]);
      addTearDown(modal.close);
      final result = await router(
        config(
          meta: await closedBaseUrl(),
          baseten: await closedBaseUrl(),
          local: await closedBaseUrl(),
          modal: modal.baseUrl,
          summaryOnModal: true,
        ),
      ).call('summary', prompt);
      expect(result.result.content, 'glimmer summary');
      expect(result.costUsd, 0);
      expect(
        modal.requests.single.authorization,
        'Bearer modal-test-key-000004',
      );
      final body = modal.requests.single.body!;
      expect(body['temperature'], 1.0);
      expect(
        ((body['messages'] as List).first as Map)['content'],
        startsWith('Reasoning strength: low.'),
      );
      expect(usage.forProvider('modal').calls, 1);
      expect(usage.forProvider('modal').completionTokens, 90);
    },
  );

  test(
    'Modal failing or not configured falls back to baseten, logged',
    () async {
      final modal = await FakeProvider.start([
        const FakeReply(503, {'error': 'cold'}),
      ]);
      final baseten = await FakeProvider.start([
        FakeReply.chat('spark open summary'),
      ]);
      addTearDown(modal.close);
      addTearDown(baseten.close);
      final failing = await router(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
          modal: modal.baseUrl,
          summaryOnModal: true,
        ),
      ).call('summary', prompt);
      expect(failing.fellBackFrom, 'modal');
      expect(failing.result.content, 'spark open summary');
      expect(modal.requests, hasLength(3));
      expect(
        logs.where(
          (line) => line.startsWith('FALLBACK: role "summary" failed on modal'),
        ),
        hasLength(1),
      );

      logs.clear();
      final unconfigured = await router(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
          summaryOnModal: true,
        ),
      ).call('summary', prompt);
      expect(unconfigured.fellBackFrom, 'modal');
      expect(logs.single, contains('no base URL is configured'));
    },
  );

  test('DOC_MODAL_BASE_URL supplies the Modal endpoint', () async {
    final modal = await FakeProvider.start([FakeReply.chat('from env url')]);
    addTearDown(modal.close);
    final result = await ModelRouter(
      config: config(
        meta: await closedBaseUrl(),
        baseten: await closedBaseUrl(),
        local: await closedBaseUrl(),
        summaryOnModal: true,
      ),
      environment: {...env, 'DOC_MODAL_BASE_URL': modal.baseUrl},
      usage: usage,
      client: ChatClient(maxRetries: 0, sleep: (_) async {}),
      log: logs.add,
    ).call('summary', prompt);
    expect(result.result.content, 'from env url');
    expect(result.fellBackFrom, isNull);
  });

  test(
    'workhorse falls back from baseten to fireworks, and no further',
    () async {
      final baseten = await FakeProvider.start([
        const FakeReply(500, {'error': 'x'}),
      ]);
      final fireworks = await FakeProvider.start([
        FakeReply.chat('fireworks draft', prompt: 100, completion: 100),
      ]);
      addTearDown(baseten.close);
      addTearDown(fireworks.close);
      final result = await router(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
          fireworks: fireworks.baseUrl,
        ),
      ).call('workhorse', prompt);
      expect(result.fellBackFrom, 'baseten');
      final sent = fireworks.requests.single;
      expect(sent.body!['model'], fireworksSparkOpenModel);
      expect(sent.body!['reasoning_effort'], 'low');
      expect(sent.authorization, 'Bearer fireworks-test-key-03');
      expect(result.costUsd, closeTo((100 * 1.25 + 100 * 4.25) / 1e6, 1e-12));
      expect(
        logs.where(
          (line) =>
              line.startsWith('FALLBACK: role "workhorse" failed on baseten'),
        ),
        hasLength(1),
      );

      // When the fallback fails too, its error surfaces: there is no chain.
      final down = await FakeProvider.start([
        const FakeReply(502, {'error': 'y'}),
      ]);
      addTearDown(down.close);
      await expectLater(
        router(
          config(
            meta: await closedBaseUrl(),
            baseten: baseten.baseUrl,
            local: await closedBaseUrl(),
            fireworks: down.baseUrl,
          ),
        ).call('workhorse', prompt),
        throwsA(
          isA<ModelCallException>().having(
            (e) => e.provider,
            'provider',
            'fireworks',
          ),
        ),
      );
    },
  );

  test('--local refuses Modal: it is not this Mac', () async {
    final modal = await FakeProvider.start([FakeReply.chat('never')]);
    addTearDown(modal.close);
    final settings = config(
      meta: await closedBaseUrl(),
      baseten: await closedBaseUrl(),
      local: await closedBaseUrl(),
      modal: modal.baseUrl,
    );
    final routed = router(settings, localOnly: true);
    expect(routed.resolve('summary').provider.id, 'local');
    await expectLater(
      routed.callProvider(
        settings.providers['modal']!,
        modalGlimmerModel,
        prompt,
      ),
      throwsA(
        isA<ModelCallException>().having(
          (e) => e.kind,
          'kind',
          ModelCallFailure.refused,
        ),
      ),
    );
    expect(modal.requests, isEmpty);
  });

  test(
    'workhorse defaults to baseten and falls back to fireworks, logged',
    () async {
      final baseten = await FakeProvider.start([
        const FakeReply(503, {'error': 'busy'}),
      ]);
      final fireworks = await FakeProvider.start([
        FakeReply.chat('fireworks summary'),
      ]);
      addTearDown(baseten.close);
      addTearDown(fireworks.close);
      final result = await router(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
          fireworks: fireworks.baseUrl,
        ),
      ).call('workhorse', prompt);
      expect(result.result.content, 'fireworks summary');
      expect(result.fellBackFrom, 'baseten');
      expect(baseten.requests.first.body!['model'], basetenSparkOpenModel);
      expect(
        logs.where(
          (line) =>
              line.startsWith('FALLBACK: role "workhorse" failed on baseten'),
        ),
        hasLength(1),
      );
    },
  );

  test('summary defaults to Modal Glimmer, falling back to baseten', () async {
    final baseten = await FakeProvider.start([FakeReply.chat('spark open')]);
    addTearDown(baseten.close);
    // No Modal deployment configured on this machine.
    final result = await router(
      config(
        meta: await closedBaseUrl(),
        baseten: baseten.baseUrl,
        local: await closedBaseUrl(),
      ),
    ).call('summary', prompt);
    expect(result.result.content, 'spark open');
    expect(result.fellBackFrom, 'modal');
    expect(
      logs.where(
        (line) => line.startsWith('FALLBACK: role "summary" failed on modal'),
      ),
      hasLength(1),
    );
  });

  group('fireworks unavailable', () {
    ModelRouter withoutFireworksKey(DocConfig config) => ModelRouter(
      config: config,
      environment: {...env}..remove('FIREWORKS_API_KEY'),
      usage: usage,
      client: ChatClient(maxRetries: 0, sleep: (_) async {}),
      log: logs.add,
    );

    test('a missing key: the fallback is skipped and the primary error is '
        'reported', () async {
      final baseten = await FakeProvider.start([
        const FakeReply(503, {'error': 'busy'}),
      ]);
      final fireworks = await FakeProvider.start([FakeReply.chat('never')]);
      addTearDown(baseten.close);
      addTearDown(fireworks.close);
      final call = withoutFireworksKey(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
          fireworks: fireworks.baseUrl,
        ),
      ).call('workhorse', prompt);
      await expectLater(
        call,
        throwsA(
          isA<ModelCallException>()
              .having((e) => e.provider, 'provider', 'baseten')
              .having((e) => e.statusCode, 'status', 503),
        ),
      );
      expect(fireworks.requests, isEmpty);
      expect(
        logs,
        contains(
          'fireworks unavailable (FIREWORKS_API_KEY is not set): role "workhorse" failed on baseten and its fallback was skipped.',
        ),
      );
      expect(logs.where((line) => line.startsWith('FALLBACK:')), isEmpty);
    });

    test(
      'a rejected key: reported, then skipped for the rest of the run',
      () async {
        final baseten = await FakeProvider.start([
          const FakeReply(503, {'error': 'busy'}),
        ]);
        final fireworks = await FakeProvider.start([
          const FakeReply(401, {'error': 'invalid api key'}),
        ]);
        addTearDown(baseten.close);
        addTearDown(fireworks.close);
        final routed = router(
          config(
            meta: await closedBaseUrl(),
            baseten: baseten.baseUrl,
            local: await closedBaseUrl(),
            fireworks: fireworks.baseUrl,
          ),
        );
        for (var i = 0; i < 2; i++) {
          await expectLater(
            routed.call('workhorse', prompt),
            throwsA(
              isA<ModelCallException>().having(
                (e) => e.provider,
                'provider',
                'baseten',
              ),
            ),
          );
        }
        expect(fireworks.requests, hasLength(1));
        expect(
          logs,
          contains(
            'fireworks unavailable (key rejected, HTTP 401): the fallback for role "workhorse" was skipped.',
          ),
        );
      },
    );

    test('a working primary never touches fireworks', () async {
      final baseten = await FakeProvider.start([FakeReply.chat('fine')]);
      addTearDown(baseten.close);
      final result = await withoutFireworksKey(
        config(
          meta: await closedBaseUrl(),
          baseten: baseten.baseUrl,
          local: await closedBaseUrl(),
        ),
      ).call('workhorse', prompt);
      expect(result.result.content, 'fine');
      expect(logs, isEmpty);
    });
  });
}
