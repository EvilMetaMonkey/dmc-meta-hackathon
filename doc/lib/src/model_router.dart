import 'config.dart';
import 'model_client.dart';
import 'redaction.dart';
import 'usage.dart';

/// A role resolved to a provider and model for this run.
class ResolvedRole {
  final String role;
  final ProviderConfig provider;
  final String model;
  final ProviderConfig? fallbackProvider;
  final String? fallbackModel;

  const ResolvedRole({
    required this.role,
    required this.provider,
    required this.model,
    this.fallbackProvider,
    this.fallbackModel,
  });
}

/// What one role call would send: the request body after redaction, and how
/// much was redacted. The API key is never part of it.
class PreparedCall {
  final ResolvedRole route;
  final Map<String, Object?> body;
  final Map<String, int> redactions;

  const PreparedCall(this.route, this.body, this.redactions);

  int get redactionCount => redactions.values.fold(0, (sum, v) => sum + v);
}

class RoleCallResult {
  final ChatResult result;
  final double costUsd;
  final int redactionCount;

  /// The provider that failed before the fallback answered, if any.
  final String? fellBackFrom;

  const RoleCallResult(
    this.result,
    this.costUsd,
    this.redactionCount, {
    this.fellBackFrom,
  });
}

/// Routes role calls to providers. Every prompt is redacted before it is
/// sent; hosted calls also need a key, a configured price and budget room.
/// `--local` ([localOnly]) sends every role to the local provider and refuses
/// any hosted call. The only fallback is a role's configured hosted
/// fallback, used after the primary hosted provider fails, and it is always
/// logged.
class ModelRouter {
  final DocConfig config;
  final Map<String, String> environment;
  final UsageStore usage;
  final ChatClient client;
  final bool localOnly;

  /// One-run `--role-provider role=provider` overrides.
  final Map<String, String> roleProviders;
  final void Function(String message) log;

  ModelRouter({
    required this.config,
    required this.environment,
    required this.usage,
    required this.client,
    this.localOnly = false,
    this.roleProviders = const {},
    void Function(String message)? log,
  }) : log = log ?? ((_) {});

  Redactor get redactor => Redactor(
    knownSecrets: [
      for (final provider in config.providers.values)
        if (provider.keyEnv != null && environment[provider.keyEnv] != null)
          environment[provider.keyEnv]!,
    ],
  );

  ProviderConfig _provider(String id) {
    final provider = config.providers[id];
    if (provider == null) {
      throw ArgumentError(
        'Unknown provider "$id". Known: ${config.providers.keys.join(', ')}.',
      );
    }
    return provider;
  }

  ResolvedRole resolve(String role) {
    final roleConfig = config.roles[role];
    if (roleConfig == null) {
      throw ArgumentError(
        'Unknown role "$role". Known: ${config.roles.keys.join(', ')}.',
      );
    }
    if (localOnly) {
      final local = _provider('local');
      return ResolvedRole(
        role: role,
        provider: local,
        model: local.defaultModel,
      );
    }
    final override = roleProviders[role];
    if (override != null) {
      final provider = _provider(override);
      return ResolvedRole(
        role: role,
        provider: provider,
        model: override == roleConfig.provider
            ? roleConfig.model
            : provider.defaultModel,
      );
    }
    final provider = _provider(roleConfig.provider);
    final fallback = roleConfig.fallbackProvider == null || !provider.hosted
        ? null
        : _provider(roleConfig.fallbackProvider!);
    return ResolvedRole(
      role: role,
      provider: provider,
      model: roleConfig.model,
      fallbackProvider: fallback != null && fallback.hosted ? fallback : null,
      fallbackModel: fallback != null && fallback.hosted
          ? roleConfig.fallbackModel ?? fallback.defaultModel
          : null,
    );
  }

  /// Redact [messages] and build the request [role] would send.
  PreparedCall prepare(
    String role,
    List<ChatMessage> messages, {
    int maxTokens = 400,
    Map<String, Object?>? responseFormat,
  }) => _prepareFor(
    resolve(role),
    messages,
    maxTokens: maxTokens,
    responseFormat: responseFormat,
  );

  PreparedCall _prepareFor(
    ResolvedRole route,
    List<ChatMessage> messages, {
    required int maxTokens,
    ProviderConfig? provider,
    String? model,
    Map<String, Object?>? responseFormat,
  }) {
    final redactor = this.redactor;
    final counts = <String, int>{};
    final redacted = [
      for (final message in messages)
        () {
          final result = redactor.redact(message.content);
          result.byKind.forEach(
            (kind, count) => counts[kind] = (counts[kind] ?? 0) + count,
          );
          return ChatMessage(message.role, result.text);
        }(),
    ];
    return PreparedCall(
      route,
      chatRequestBody(
        provider: provider ?? route.provider,
        model: model ?? route.model,
        messages: redacted,
        maxTokens: maxTokens,
        reasoningEffort: config.reasoningEffort,
        responseFormat: responseFormat,
      ),
      counts,
    );
  }

  /// Providers found unavailable this run (key missing or rejected); they
  /// are skipped as fallbacks.
  final Map<String, String> unavailable = {};

  /// Why [provider] cannot be used at all, or null: its key is not set, or
  /// it was rejected earlier in this run.
  String? unavailableReason(ProviderConfig provider) {
    final known = unavailable[provider.id];
    if (known != null) return known;
    final keyEnv = provider.keyEnv;
    if (provider.hosted &&
        keyEnv != null &&
        (environment[keyEnv] ?? '').isEmpty) {
      return '$keyEnv is not set';
    }
    return null;
  }

  /// A missing or rejected key: the provider cannot serve anything until the
  /// user fixes it.
  static bool isUnavailableError(ModelCallException error) =>
      error.kind == ModelCallFailure.missingKey ||
      (error.kind == ModelCallFailure.http &&
          (error.statusCode == 401 || error.statusCode == 403));

  /// Call [role] with [messages]. [responseFormat] (a JSON schema) is sent
  /// only to providers that accept it.
  Future<RoleCallResult> call(
    String role,
    List<ChatMessage> messages, {
    int maxTokens = 400,
    Map<String, Object?>? responseFormat,
  }) async {
    final route = resolve(role);
    try {
      return await _callOn(
        route,
        route.provider,
        route.model,
        messages,
        maxTokens,
        responseFormat,
      );
    } on ModelCallException catch (error, stack) {
      final fallback = route.fallbackProvider;
      final fallbackEligible =
          fallback != null &&
          !localOnly &&
          route.provider.hosted &&
          // Only a provider failure after retries; never a configuration
          // problem such as a missing key, a rejected key or a used-up
          // budget.
          (error.retryable ||
              error.kind == ModelCallFailure.unreachable ||
              error.kind == ModelCallFailure.badResponse ||
              // A private deployment that is not set up on this machine.
              error.kind == ModelCallFailure.notConfigured);
      if (!fallbackEligible) rethrow;
      final reason = unavailableReason(fallback);
      if (reason != null) {
        log(
          '${fallback.id} unavailable ($reason): role "$role" failed on ${route.provider.id} and its fallback was skipped.',
        );
        rethrow;
      }
      log(
        'FALLBACK: role "$role" failed on ${route.provider.id} (${route.model}): ${error.message.replaceFirst(RegExp(r'\.$'), '')}. Using the configured fallback ${fallback.id} (${route.fallbackModel}).',
      );
      final RoleCallResult result;
      try {
        result = await _callOn(
          route,
          fallback,
          route.fallbackModel!,
          messages,
          maxTokens,
          responseFormat,
        );
      } on ModelCallException catch (fallbackError) {
        if (!isUnavailableError(fallbackError)) rethrow;
        final why = fallbackError.kind == ModelCallFailure.missingKey
            ? '${fallback.keyEnv} is not set'
            : 'key rejected, HTTP ${fallbackError.statusCode}';
        unavailable[fallback.id] = why;
        log(
          '${fallback.id} unavailable ($why): the fallback for role "$role" was skipped.',
        );
        // Report the primary provider's failure, not the fallback's.
        Error.throwWithStackTrace(error, stack);
      }
      return RoleCallResult(
        result.result,
        result.costUsd,
        result.redactionCount,
        fellBackFrom: route.provider.id,
      );
    }
  }

  /// Call [provider] directly (for `doc models --check`), with the same
  /// redaction, key, price, budget and `--local` checks as a role call.
  Future<RoleCallResult> callProvider(
    ProviderConfig provider,
    String model,
    List<ChatMessage> messages, {
    int maxTokens = 64,
  }) => _callOn(
    ResolvedRole(role: 'check', provider: provider, model: model),
    provider,
    model,
    messages,
    maxTokens,
    null,
  );

  Future<RoleCallResult> _callOn(
    ResolvedRole route,
    ProviderConfig provider,
    String model,
    List<ChatMessage> messages,
    int maxTokens,
    Map<String, Object?>? responseFormat,
  ) async {
    if (localOnly && provider.hosted) {
      throw ModelCallException(
        ModelCallFailure.refused,
        provider.id,
        '--local refuses hosted calls; ${provider.id} was not called.',
      );
    }
    final baseUrl = provider.resolvedBaseUrl(environment);
    if (baseUrl.isEmpty) {
      throw ModelCallException(
        ModelCallFailure.notConfigured,
        provider.id,
        '${provider.id}: no base URL is configured. Set providers.${provider.id}.baseUrl in the config${provider.baseUrlEnv == null ? '' : ' or ${provider.baseUrlEnv}'}.',
      );
    }
    provider = provider.withBaseUrl(baseUrl);
    String? key;
    ModelPrice? price;
    if (provider.hosted && provider.keyEnv != null) {
      key = environment[provider.keyEnv];
      if (key == null || key.isEmpty) {
        throw ModelCallException(
          ModelCallFailure.missingKey,
          provider.id,
          '${provider.id}: ${provider.keyEnv} is not set.',
        );
      }
    }
    if (provider.billing == ProviderBilling.tokens) {
      price = provider.prices[model];
      if (price == null) {
        throw ModelCallException(
          ModelCallFailure.refused,
          provider.id,
          '${provider.id}: no price is configured for $model, so its budget cannot be enforced. Add it under providers.${provider.id}.prices in the config.',
        );
      }
      final spent = usage.forProvider(provider.id).costUsd;
      final budget = provider.budgetUsd;
      if (budget != null && spent >= budget) {
        throw ModelCallException(
          ModelCallFailure.budgetExceeded,
          provider.id,
          '${provider.id}: the budget of \$${budget.toStringAsFixed(2)} is used up (\$${spent.toStringAsFixed(4)} spent). Raise providers.${provider.id}.budgetUsd in the config to continue.',
        );
      }
    }
    final prepared = _prepareFor(
      route,
      messages,
      maxTokens: maxTokens,
      provider: provider,
      model: model,
      responseFormat: responseFormat,
    );
    final result = await client.complete(
      provider: provider,
      body: prepared.body,
      apiKey: key,
    );
    final cost = price?.cost(result.promptTokens, result.completionTokens) ?? 0;
    usage.record(
      provider.id,
      result.promptTokens,
      result.completionTokens,
      cost,
    );
    if (result.content.isEmpty) {
      throw ModelCallException(
        ModelCallFailure.truncated,
        provider.id,
        result.finishReason == 'length'
            ? '${provider.id}: $model used all $maxTokens completion tokens (mostly reasoning) before answering. Raise the token limit.'
            : '${provider.id}: $model returned an empty answer (finish_reason ${result.finishReason}).',
      );
    }
    return RoleCallResult(result, cost, prepared.redactionCount);
  }
}
