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

/// One OpenAI-compatible endpoint.
class ProviderConfig {
  final String id;
  final String baseUrl;

  /// The environment variable that holds the API key; null for no key.
  final String? keyEnv;
  final String defaultModel;

  /// Hosted providers get redacted prompts, budgets and fallbacks; the local
  /// provider never falls back to a hosted one.
  final bool hosted;
  final Map<String, ModelPrice> prices;

  /// Spending limit in USD; calls are blocked once usage reaches it.
  final double? budgetUsd;
  final Duration timeout;

  const ProviderConfig({
    required this.id,
    required this.baseUrl,
    required this.keyEnv,
    required this.defaultModel,
    required this.hosted,
    this.prices = const {},
    this.budgetUsd,
    this.timeout = const Duration(seconds: 90),
  });

  ProviderConfig copyWith({String? baseUrl, String? defaultModel}) =>
      ProviderConfig(
        id: id,
        baseUrl: baseUrl ?? this.baseUrl,
        keyEnv: keyEnv,
        defaultModel: defaultModel ?? this.defaultModel,
        hosted: hosted,
        prices: prices,
        budgetUsd: budgetUsd,
        timeout: timeout,
      );

  Map<String, Object?> toJson() => {
    'baseUrl': baseUrl,
    'keyEnv': keyEnv,
    'defaultModel': defaultModel,
    'hosted': hosted,
    'prices': {
      for (final entry in prices.entries) entry.key: entry.value.toJson(),
    },
    'budgetUsd': budgetUsd,
    'timeoutSeconds': timeout.inSeconds,
  };

  static ProviderConfig fromJson(String id, Map<String, Object?> json) =>
      ProviderConfig(
        id: id,
        baseUrl: json['baseUrl'] as String,
        keyEnv: json['keyEnv'] as String?,
        defaultModel: json['defaultModel'] as String,
        hosted: json['hosted'] as bool? ?? true,
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
      ),
      'baseten': ProviderConfig(
        id: 'baseten',
        baseUrl: 'https://inference.baseten.co/v1',
        keyEnv: 'BASETEN_API_KEY',
        defaultModel: basetenSparkOpenModel,
        hosted: true,
        prices: {basetenSparkOpenModel: ModelPrice(1.25, 4.25)},
        budgetUsd: 100,
      ),
      'local': ProviderConfig(
        id: 'local',
        baseUrl: 'http://127.0.0.1:11434/v1',
        keyEnv: null,
        defaultModel: localGlimmerModel,
        hosted: false,
        timeout: Duration(seconds: 180),
      ),
    },
    roles: {
      'summary': RoleConfig(
        role: 'summary',
        provider: 'local',
        model: localGlimmerModel,
      ),
      'workhorse': RoleConfig(
        role: 'workhorse',
        provider: 'baseten',
        model: basetenSparkOpenModel,
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
