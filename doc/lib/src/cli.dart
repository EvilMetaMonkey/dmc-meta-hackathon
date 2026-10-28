import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'dmc_client.dart';
import 'model_client.dart';
import 'model_router.dart';
import 'summarize.dart';
import 'usage.dart';

/// Room for reasoning plus a 2-3 sentence answer.
const int summaryMaxTokens = 1500;

const String docUsage = '''
Doc: the AI companion for dmc. Doc reads dmc only through its JSON interface
and never writes workspace files.

Usage: doc <command> [options]

Commands:
  models [--check] [--available]   Show each role's provider and model, and
                                   whether its key is set. --check sends one
                                   tiny prompt per provider; --available lists
                                   each provider's model IDs.
  summarize <checkpoint-id>        Summarize a checkpoint in plain English.
  usage                            Tokens and estimated cost per provider.

Options:
  --dmc <path>                     The dmc executable (else DMC_BIN, then PATH).
  --workspace <dir>                The dmc workspace (default: current dir).
  --local                          Use only this Mac's model server; refuse hosted
                                   and Modal calls.
  --role-provider <role>=<provider>
                                   Use another provider for one role, this run.
  --show-prompt                    Print exactly what would be sent; send nothing.
''';

ArgParser _parser() => ArgParser()
  ..addOption('dmc')
  ..addOption('workspace')
  ..addFlag('local', negatable: false)
  ..addMultiOption('role-provider')
  ..addFlag('show-prompt', negatable: false)
  ..addFlag('check', negatable: false)
  ..addFlag('available', negatable: false)
  ..addFlag('help', abbr: 'h', negatable: false);

/// Run Doc. Output goes to [out], diagnostics (retries, fallbacks, errors)
/// to [err]. Returns the process exit code: 0 success, 1 failure, 2 usage.
Future<int> runDoc(
  List<String> arguments, {
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
  ChatClient? client,
}) async {
  final env = environment ?? Platform.environment;
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  void log(String message) => stderrSink.writeln('[doc] $message');

  final ArgResults args;
  try {
    args = _parser().parse(arguments);
  } on FormatException catch (error) {
    stderrSink.writeln('[doc] ${error.message}\n\n$docUsage');
    return 2;
  }
  if (args['help'] as bool || args.rest.isEmpty) {
    stdoutSink.write(docUsage);
    return args.rest.isEmpty && !(args['help'] as bool) ? 2 : 0;
  }

  final configDir = docConfigDirectory(env);
  final configFile = File(p.join(configDir, 'config.json'));
  final DocConfig config;
  try {
    config = DocConfig.load(configFile);
  } catch (error) {
    log('Cannot read ${configFile.path}: $error');
    return 1;
  }
  final overrides = <String, String>{};
  for (final value in args['role-provider'] as List<String>) {
    final parts = value.split('=');
    if (parts.length != 2 || parts.any((part) => part.trim().isEmpty)) {
      log(
        '--role-provider takes <role>=<provider>, for example summary=baseten.',
      );
      return 2;
    }
    overrides[parts[0].trim()] = parts[1].trim();
  }
  final router = ModelRouter(
    config: config,
    environment: env,
    usage: UsageStore(File(p.join(configDir, 'usage.json'))),
    client: client ?? ChatClient(maxRetries: config.maxRetries, log: log),
    localOnly: args['local'] as bool,
    roleProviders: overrides,
    log: log,
  );
  final context = _Context(
    args: args,
    env: env,
    config: config,
    configFile: configFile,
    router: router,
    out: stdoutSink,
    log: log,
  );

  try {
    switch (args.rest.first) {
      case 'models':
        return await _models(context);
      case 'summarize':
        return await _summarize(context);
      case 'usage':
        return _usage(context);
      default:
        log('Unknown command "${args.rest.first}".\n\n$docUsage');
        return 2;
    }
  } on ArgumentError catch (error) {
    log('${error.message}');
    return 2;
  }
}

class _Context {
  final ArgResults args;
  final Map<String, String> env;
  final DocConfig config;
  final File configFile;
  final ModelRouter router;
  final StringSink out;
  final void Function(String message) log;

  const _Context({
    required this.args,
    required this.env,
    required this.config,
    required this.configFile,
    required this.router,
    required this.out,
    required this.log,
  });

  String keyStatus(ProviderConfig provider) => !provider.hosted
      ? 'no key needed'
      : provider.keyEnv == null
      ? 'no key configured'
      : '${provider.keyEnv} ${(env[provider.keyEnv] ?? '').isEmpty ? 'NOT set' : 'set'}';
}

String _pad(String value, int width) =>
    value.length >= width ? '$value ' : value.padRight(width);

Future<int> _models(_Context context) async {
  final out = context.out;
  out.writeln(
    'Config: ${context.configFile.path}${context.configFile.existsSync() ? '' : ' (not found; using defaults)'}',
  );
  if (context.router.localOnly) {
    out.writeln(
      'Mode: --local (this Mac only; hosted and Modal calls refused)',
    );
  }
  out.writeln(
    '${_pad('Role', 11)}${_pad('Provider', 33)}${_pad('Model', 43)}Key',
  );
  final probes = <String, String>{};
  for (final role in context.config.roles.keys) {
    final route = context.router.resolve(role);
    final roleConfig = context.config.roles[role]!;
    final fallback = route.fallbackProvider == null
        ? ''
        : '  (fallback: ${route.fallbackProvider!.id} ${route.fallbackModel})';
    out.writeln(
      '${_pad(role, 11)}${_pad(route.provider.label, 33)}${_pad(route.model, 43)}${context.keyStatus(route.provider)}${roleConfig.chat ? '' : '  (transcription; not wired up yet)'}$fallback',
    );
    if (roleConfig.chat) {
      probes.putIfAbsent(route.provider.id, () => route.model);
      if (route.fallbackProvider != null) {
        probes.putIfAbsent(
          route.fallbackProvider!.id,
          () => route.fallbackModel!,
        );
      }
    }
  }
  for (final provider in context.config.providers.values) {
    if (context.router.localOnly && provider.hosted) continue;
    final url = provider.resolvedBaseUrl(context.env);
    out.writeln(
      'Provider ${provider.label}: ${url.isEmpty ? 'not configured (set providers.${provider.id}.baseUrl${provider.baseUrlEnv == null ? '' : ' or ${provider.baseUrlEnv}'})' : url}',
    );
  }

  var failed = false;
  if (context.args['available'] as bool) {
    out.writeln('');
    for (final configured in context.config.providers.values) {
      if (context.router.localOnly && configured.hosted) continue;
      final url = configured.resolvedBaseUrl(context.env);
      if (url.isEmpty) {
        out.writeln('${configured.id} models: skipped (not configured)');
        continue;
      }
      final provider = configured.withBaseUrl(url);
      final key = provider.keyEnv == null ? null : context.env[provider.keyEnv];
      if (provider.keyEnv != null && (key == null || key.isEmpty)) {
        out.writeln(
          '${provider.id} models: skipped (${provider.keyEnv} not set)',
        );
        continue;
      }
      try {
        final ids = await context.router.client.listModels(provider, key);
        out.writeln('${provider.id} models (${ids.length}): ${ids.join(', ')}');
      } on ModelCallException catch (error) {
        out.writeln(
          '${provider.id} models: ${_explain(error, provider, localOnly: context.router.localOnly)}',
        );
      }
    }
  }

  if (context.args['check'] as bool) {
    out.writeln('');
    for (final entry in probes.entries) {
      final provider = context.config.providers[entry.key]!;
      final label = '${_pad(provider.id, 10)}${_pad(entry.value, 43)}';
      try {
        final result = await context.router.callProvider(
          provider,
          entry.value,
          const [ChatMessage('user', 'Reply with the single word: ok')],
          // Muse models reason before answering, even for "ok".
          maxTokens: 600,
        );
        out.writeln(
          '${label}ok  ${result.result.latency.inMilliseconds} ms  '
          '${result.result.promptTokens} in / ${result.result.completionTokens} out  '
          '${provider.billing == ProviderBilling.gpuTime ? 'billed by GPU time' : '\$${result.costUsd.toStringAsFixed(6)}'}  '
          'reply: ${jsonEncode(_short(result.result.content))}',
        );
      } on ModelCallException catch (error) {
        failed = true;
        out.writeln(
          '${label}FAILED  ${_explain(error, provider, localOnly: context.router.localOnly)}',
        );
      }
    }
  }
  return failed ? 1 : 0;
}

String _short(String text) =>
    text.length > 60 ? '${text.substring(0, 60)}…' : text;

/// A plain explanation of a failed call, with what to do next.
String _explain(
  ModelCallException error,
  ProviderConfig provider, {
  String? role,
  bool localOnly = false,
}) {
  final alternative = role == null
      ? ''
      : localOnly
      ? ', or run without --local'
      : ', or run once with --role-provider $role=baseten';
  if (!provider.hosted && error.kind == ModelCallFailure.unreachable) {
    return 'The local model server is not running at ${provider.baseUrl} (${error.message.split('(').last.replaceAll(')', '')}). '
        'Start Ollama, LM Studio or llama-server$alternative.';
  }
  if (!provider.hosted && error.statusCode == 404) {
    return 'The local server at ${provider.baseUrl} has no model "${provider.defaultModel}" (HTTP 404). '
        'Load it there, set providers.local.defaultModel in the config$alternative.';
  }
  return error.message;
}

Future<int> _summarize(_Context context) async {
  final args = context.args;
  if (args.rest.length != 2) {
    context.log(
      'Usage: doc summarize <checkpoint-id> [--local] [--show-prompt]',
    );
    return 2;
  }
  final id = args.rest[1];
  final workspace = p.normalize(
    p.absolute(args['workspace'] as String? ?? Directory.current.path),
  );
  final DmcClient dmc;
  final Map<String, Object?> show;
  final Map<String, Object?> diff;
  try {
    dmc = await DmcClient.locate(
      explicit: args['dmc'] as String?,
      environment: context.env,
    );
    show = await dmc.runJson(['checkpoint', 'show', id], workspace: workspace);
    diff = await dmc.runJson(['checkpoint', 'diff', id], workspace: workspace);
  } on DmcException catch (error) {
    context.log(error.message);
    return 1;
  }
  for (final envelope in [show, diff]) {
    if (envelope['ok'] != true) {
      final errors = (envelope['errors'] as List? ?? const [])
          .whereType<Map>()
          .map((error) => '${error['code']}: ${error['message']}')
          .join('; ');
      context.log('dmc ${envelope['command']} failed: $errors');
      return 1;
    }
  }
  final messages = summaryMessages(show, diff);

  if (args['show-prompt'] as bool) {
    final prepared = context.router.prepare(
      'summary',
      messages,
      maxTokens: summaryMaxTokens,
    );
    context.out
      ..writeln(
        'Would send to ${prepared.route.provider.id} (${prepared.route.model}) at '
        '${prepared.route.provider.baseUrl}/chat/completions. Nothing was sent.',
      )
      ..writeln('Redacted: ${prepared.redactionCount} item(s)')
      ..writeln(const JsonEncoder.withIndent('  ').convert(prepared.body));
    return 0;
  }

  final route = context.router.resolve('summary');
  try {
    final call = await context.router.call(
      'summary',
      messages,
      maxTokens: summaryMaxTokens,
    );
    final result = call.result;
    context.out
      ..writeln(result.content)
      ..writeln('')
      ..writeln(
        '(${result.provider} ${result.model}; ${result.promptTokens} in / ${result.completionTokens} out; '
        '\$${call.costUsd.toStringAsFixed(6)}; ${result.latency.inMilliseconds} ms; '
        '${call.redactionCount} item(s) redacted${call.fellBackFrom == null ? '' : '; fell back from ${call.fellBackFrom}'})',
      );
    return 0;
  } on ModelCallException catch (error) {
    final provider = context.config.providers[error.provider] ?? route.provider;
    context.log(
      _explain(
        error,
        provider,
        role: 'summary',
        localOnly: context.router.localOnly,
      ),
    );
    return 1;
  }
}

int _usage(_Context context) {
  final usage = context.router.usage.read();
  context.out.writeln('Usage file: ${context.router.usage.file.path}');
  context.out.writeln(
    '${_pad('Provider', 10)}${_pad('Calls', 7)}${_pad('Tokens in', 11)}${_pad('Tokens out', 12)}${_pad('Cost', 12)}Budget',
  );
  for (final provider in context.config.providers.values) {
    final used = usage[provider.id] ?? const ProviderUsage();
    final budget = provider.budgetUsd;
    final String cost;
    final String limit;
    switch (provider.billing) {
      case ProviderBilling.gpuTime:
        cost = 'n/a';
        limit = 'billed by GPU time on Modal; check the Modal dashboard';
      case ProviderBilling.none:
        cost = 'n/a';
        limit = 'n/a (this Mac)';
      case ProviderBilling.tokens:
        cost = '\$${used.costUsd.toStringAsFixed(4)}';
        limit = budget == null
            ? 'none'
            : '\$${budget.toStringAsFixed(2)} (\$${(budget - used.costUsd).clamp(0, budget).toStringAsFixed(4)} left)';
    }
    context.out.writeln(
      '${_pad(provider.id, 10)}${_pad('${used.calls}', 7)}${_pad('${used.promptTokens}', 11)}'
      '${_pad('${used.completionTokens}', 12)}${_pad(cost, 12)}$limit',
    );
  }
  return 0;
}
