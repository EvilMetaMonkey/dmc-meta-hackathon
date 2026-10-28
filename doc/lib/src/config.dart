import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Price of one model in USD per million tokens.
class ModelPrice {
  final double inputPerMillion;
  final double outputPerMillion;

  const ModelPrice(this.inputPerMillion, this.outputPerMillion);

  double cost(int promptTokens, int completionTokens) =>
      (promptTokens * inputPerMillion + completionTokens * outputPerMillion) /
      1e6;

  Map<String, Object?> toJson() => {
    'inputPerMillion': inputPerMillion,
    'outputPerMillion': outputPerMillion,
  };

  static ModelPrice fromJson(Map<String, Object?> json) => ModelPrice(
    (json['inputPerMillion'] as num).toDouble(),
    (json['outputPerMillion'] as num).toDouble(),
  );
}

/// How a provider bills, which decides budget enforcement.
enum ProviderBilling {
  /// Per token at the configured prices; budgets are enforced.
  tokens,

  /// By GPU time on the host (Modal). Doc records calls and tokens but
  /// cannot see GPU-seconds, so there is no price or budget check.
  gpuTime,

  /// No charge (the local server).
  none,
}

/// One OpenAI-compatible endpoint.
class ProviderConfig {
  final String id;

  /// The base URL, or empty when it must come from [baseUrlEnv].
  final String baseUrl;

  /// An environment variable that overrides [baseUrl], for example
  /// `DOC_MODAL_BASE_URL`.
  final String? baseUrlEnv;

  /// The environment variable that holds the API key; null for no key.
  final String? keyEnv;
  final String defaultModel;

  /// A short label for `doc models`, for example "your private deployment".
  final String? description;

  /// Hosted providers get redacted prompts and may be a fallback target;
  /// they are refused under `--local`. Only the Mac's own server is not
  /// hosted, and it never falls back to a hosted one.
  final bool hosted;
  final ProviderBilling billing;
  final Map<String, ModelPrice> prices;

  /// Spending limit in USD; calls are blocked once usage reaches it.
  final double? budgetUsd;
  final Duration timeout;

  /// Request style. `reasoning_effort` is sent to models that always reason
  /// (Muse Spark); the token limit goes in [tokenLimitField].
  final bool sendReasoningEffort;
  final String tokenLimitField;

  /// Sampling parameters sent with every request (for example Muse
  /// Glimmer's recommended temperature 1.0, top_p 0.95, top_k 64).
  final Map<String, num> sampling;

  /// Muse Glimmer's reasoning control: a `Reasoning strength: <value>` line
  /// in the system prompt (low, medium, high or xhigh).
  final String? reasoningStrength;

  /// Printed when a call has not answered after 10 s (a cold start).
  final String? wakeNotice;

  const ProviderConfig({
    required this.id,
    required this.baseUrl,
    required this.keyEnv,
    required this.defaultModel,
    required this.hosted,
    this.baseUrlEnv,
    this.description,
    this.billing = ProviderBilling.tokens,
    this.prices = const {},
    this.budgetUsd,
    this.timeout = const Duration(seconds: 90),
    this.sendReasoningEffort = false,
    this.tokenLimitField = 'max_tokens',
    this.sampling = const {},
    this.reasoningStrength,
    this.wakeNotice,
  });

  /// [baseUrl], or [baseUrlEnv]'s value when it is set.
  String resolvedBaseUrl(Map<String, String> environment) {
    final fromEnv = baseUrlEnv == null ? null : environment[baseUrlEnv];
    return (fromEnv != null && fromEnv.trim().isNotEmpty)
        ? fromEnv.trim()
        : baseUrl;
  }

  String get label => description == null ? id : '$id ($description)';

  ProviderConfig withBaseUrl(String value) => ProviderConfig(
    id: id,
    baseUrl: value,
    keyEnv: keyEnv,
    defaultModel: defaultModel,
    hosted: hosted,
    baseUrlEnv: baseUrlEnv,
    description: description,
    billing: billing,
    prices: prices,
    budgetUsd: budgetUsd,
    timeout: timeout,
    sendReasoningEffort: sendReasoningEffort,
    tokenLimitField: tokenLimitField,
    sampling: sampling,
    reasoningStrength: reasoningStrength,
    wakeNotice: wakeNotice,
  );

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'baseUrlEnv': baseUrlEnv,
    'keyEnv': keyEnv,
    'defaultModel': defaultModel,
    'description': description,
    'hosted': hosted,
    'billing': billing.name,
    'prices': {
      for (final entry in prices.entries) entry.key: entry.value.toJson(),
    },
    'budgetUsd': budgetUsd,
    'timeoutSeconds': timeout.inSeconds,
    'sendReasoningEffort': sendReasoningEffort,
    'tokenLimitField': tokenLimitField,
    'sampling': sampling,
    'reasoningStrength': reasoningStrength,
    'wakeNotice': wakeNotice,
  };

  static ProviderConfig fromJson(String id, Map<String, Object?> json) =>
      ProviderConfig(
        id: id,
        baseUrl: json['baseUrl'] as String? ?? '',
        baseUrlEnv: json['baseUrlEnv'] as String?,
        keyEnv: json['keyEnv'] as String?,
        defaultModel: json['defaultModel'] as String,
        description: json['description'] as String?,
        hosted: json['hosted'] as bool? ?? true,
        billing: ProviderBilling.values.firstWhere(
          (value) => value.name == json['billing'],
          orElse: () => ProviderBilling.tokens,
        ),
        prices: {
          for (final entry in ((json['prices'] as Map?) ?? const {}).entries)
            entry.key as String: ModelPrice.fromJson(
              (entry.value as Map).cast<String, Object?>(),
            ),
        },
        budgetUsd: (json['budgetUsd'] as num?)?.toDouble(),
        timeout: Duration(
          seconds: (json['timeoutSeconds'] as num?)?.toInt() ?? 90,
        ),
        sendReasoningEffort: json['sendReasoningEffort'] as bool? ?? false,
        tokenLimitField: json['tokenLimitField'] as String? ?? 'max_tokens',
        sampling: {
          for (final entry in ((json['sampling'] as Map?) ?? const {}).entries)
            entry.key as String: entry.value as num,
        },
        reasoningStrength: json['reasoningStrength'] as String?,
        wakeNotice: json['wakeNotice'] as String?,
      );
}

/// Which provider and model serve one role.
class RoleConfig {
  final String role;
  final String provider;
  final String model;

  /// The one explicit fallback: a hosted provider (and model) to use when
  /// [provider] fails after retries. Never set for the local provider.
  final String? fallbackProvider;
  final String? fallbackModel;

  /// Chat roles answer prompts; `voice` is transcription (configured only).
  final bool chat;

  const RoleConfig({
    required this.role,
    required this.provider,
    required this.model,
    this.fallbackProvider,
    this.fallbackModel,
    this.chat = true,
  });

  Map<String, Object?> toJson() => {
    'provider': provider,
    'model': model,
    if (fallbackProvider != null) 'fallbackProvider': fallbackProvider,
    if (fallbackModel != null) 'fallbackModel': fallbackModel,
    if (!chat) 'chat': false,
  };

  static RoleConfig fromJson(String role, Map<String, Object?> json) =>
      RoleConfig(
        role: role,
        provider: json['provider'] as String,
        model: json['model'] as String,
        fallbackProvider: json['fallbackProvider'] as String?,
        fallbackModel: json['fallbackModel'] as String?,
        chat: json['chat'] as bool? ?? true,
      );
}

const String metaSparkModel = 'muse-spark-1.3';
const String metaWonderModel = 'muse-wonder-1.0';
const String metaVoiceModel = 'muse-voice-transcribe-1.0';
const String basetenSparkOpenModel = 'meta-models/muse-spark-open-1026';
const String localGlimmerModel = 'muse-glimmer';
const String modalGlimmerModel = 'muse-glimmer';
const String fireworksSparkOpenModel =
    'accounts/fireworks/models/muse-spark-open';

/// Doc's configuration: providers and role routing.
class DocConfig {
  final Map<String, ProviderConfig> providers;
  final Map<String, RoleConfig> roles;

  /// Reasoning effort for Muse Spark on meta. Muse Spark always reasons, so
  /// "none" is never sent.
  final String reasoningEffort;
  final int maxRetries;

  const DocConfig({
    required this.providers,
    required this.roles,
    this.reasoningEffort = 'low',
    this.maxRetries = 3,
  });

  /// Defaults. Prices are each provider's published per-token prices
  /// (dev.meta.ai/docs/pricing-rate-limits and Baseten's model library,
  /// checked 2026-10-27); edit the config file if they change.
  static DocConfig defaults() => const DocConfig(
    providers: {
      'meta': ProviderConfig(
        id: 'meta',
        baseUrl: 'https://api.meta.ai/v1',
        keyEnv: 'MODEL_API_KEY',
        defaultModel: metaSparkModel,
        hosted: true,
        prices: {
          metaSparkModel: ModelPrice(1.25, 4.25),
          metaWonderModel: ModelPrice(4.00, 20.00),
        },
        budgetUsd: 150,
        sendReasoningEffort: true,
        tokenLimitField: 'max_completion_tokens',
      ),
      'baseten': ProviderConfig(
        id: 'baseten',
        baseUrl: 'https://inference.baseten.co/v1',
        keyEnv: 'BASETEN_API_KEY',
        defaultModel: basetenSparkOpenModel,
        hosted: true,
        prices: {basetenSparkOpenModel: ModelPrice(1.25, 4.25)},
        budgetUsd: 100,
        sendReasoningEffort: true,
      ),
      'fireworks': ProviderConfig(
        id: 'fireworks',
        baseUrl: 'https://api.fireworks.ai/inference/v1',
        keyEnv: 'FIREWORKS_API_KEY',
        defaultModel: fireworksSparkOpenModel,
        hosted: true,
        prices: {fireworksSparkOpenModel: ModelPrice(1.25, 4.25)},
        budgetUsd: 100,
        sendReasoningEffort: true,
      ),
      // Muse Glimmer on Mike's own Modal deployment (deploy/modal/). Not
      // local: --local refuses it. The base URL comes from the config file
      // or DOC_MODAL_BASE_URL and is never committed.
      'modal': ProviderConfig(
        id: 'modal',
        baseUrl: '',
        baseUrlEnv: 'DOC_MODAL_BASE_URL',
        keyEnv: 'MODAL_GLIMMER_KEY',
        defaultModel: modalGlimmerModel,
        description: 'your private deployment',
        hosted: true,
        billing: ProviderBilling.gpuTime,
        // A cold start loads ~60 GB of weights onto the GPU.
        timeout: Duration(seconds: 600),
        sampling: {'temperature': 1.0, 'top_p': 0.95, 'top_k': 64},
        reasoningStrength: 'low',
        wakeNotice:
            'Waking Muse Glimmer on Modal (can take a couple of minutes)…',
      ),
      'local': ProviderConfig(
        id: 'local',
        baseUrl: 'http://127.0.0.1:11434/v1',
        keyEnv: null,
        defaultModel: localGlimmerModel,
        description: 'this Mac',
        hosted: false,
        billing: ProviderBilling.none,
        timeout: Duration(seconds: 180),
        sampling: {'temperature': 1.0, 'top_p': 0.95, 'top_k': 64},
        reasoningStrength: 'low',
      ),
    },
    roles: {
      'summary': RoleConfig(
        role: 'summary',
        provider: 'modal',
        model: modalGlimmerModel,
        fallbackProvider: 'baseten',
        fallbackModel: basetenSparkOpenModel,
      ),
      'workhorse': RoleConfig(
        role: 'workhorse',
        provider: 'baseten',
        model: basetenSparkOpenModel,
        fallbackProvider: 'fireworks',
        fallbackModel: fireworksSparkOpenModel,
      ),
      'restore': RoleConfig(
        role: 'restore',
        provider: 'meta',
        model: metaSparkModel,
        fallbackProvider: 'baseten',
        fallbackModel: basetenSparkOpenModel,
      ),
      'planner': RoleConfig(
        role: 'planner',
        provider: 'meta',
        model: metaWonderModel,
      ),
      'judge': RoleConfig(
        role: 'judge',
        provider: 'meta',
        model: metaWonderModel,
      ),
      'voice': RoleConfig(
        role: 'voice',
        provider: 'meta',
        model: metaVoiceModel,
        chat: false,
      ),
    },
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'reasoningEffort': reasoningEffort,
    'maxRetries': maxRetries,
    'providers': {
      for (final entry in providers.entries) entry.key: entry.value.toJson(),
    },
    'roles': {
      for (final entry in roles.entries) entry.key: entry.value.toJson(),
    },
  };

  /// Read [file], filling anything it leaves out from [defaults].
  static DocConfig load(File file) {
    final base = defaults();
    if (!file.existsSync()) return base;
    final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final providers = {...base.providers};
    for (final entry in ((json['providers'] as Map?) ?? const {}).entries) {
      final id = entry.key as String;
      final value = (entry.value as Map).cast<String, Object?>();
      final defaults = base.providers[id];
      providers[id] = ProviderConfig.fromJson(id, {
        if (defaults != null) ...defaults.toJson(),
        ...value,
      });
    }
    final roles = {...base.roles};
    for (final entry in ((json['roles'] as Map?) ?? const {}).entries) {
      final role = entry.key as String;
      roles[role] = RoleConfig.fromJson(
        role,
        (entry.value as Map).cast<String, Object?>(),
      );
    }
    var effort = json['reasoningEffort'] as String? ?? base.reasoningEffort;
    if (effort == 'none') effort = 'low';
    return DocConfig(
      providers: providers,
      roles: roles,
      reasoningEffort: effort,
      maxRetries: (json['maxRetries'] as num?)?.toInt() ?? base.maxRetries,
    );
  }
}

/// Doc's directory in the user config dir: `$DOC_CONFIG_DIR`, else
/// `$XDG_CONFIG_HOME/dmc-doc`, `~/.config/dmc-doc`, or `%APPDATA%\dmc-doc`
/// on Windows. Doc writes only here, never in a workspace.
String docConfigDirectory(Map<String, String> environment) {
  final explicit = environment['DOC_CONFIG_DIR'];
  if (explicit != null && explicit.isNotEmpty) return explicit;
  if (Platform.isWindows) {
    final appData = environment['APPDATA'];
    if (appData != null) return p.join(appData, 'dmc-doc');
  }
  final xdg = environment['XDG_CONFIG_HOME'];
  if (xdg != null && xdg.isNotEmpty) return p.join(xdg, 'dmc-doc');
  final home = environment['HOME'] ?? environment['USERPROFILE'];
  if (home == null) {
    throw StateError('Cannot find the home directory for Doc\'s config.');
  }
  return p.join(home, '.config', 'dmc-doc');
}
