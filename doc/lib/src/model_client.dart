import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'config.dart';

class ChatMessage {
  final String role;
  final String content;

  const ChatMessage(this.role, this.content);

  Map<String, Object?> toJson() => {'role': role, 'content': content};
}

/// One completed chat call.
class ChatResult {
  /// `message.content` only; `reasoning_content` is always dropped.
  final String content;
  final String provider;
  final String model;
  final int promptTokens;
  final int completionTokens;
  final Duration latency;
  final int attempts;

  /// The provider's finish reason, for example `stop` or `length`.
  final String? finishReason;

  const ChatResult({
    required this.content,
    required this.provider,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.latency,
    required this.attempts,
    this.finishReason,
  });
}

enum ModelCallFailure {
  /// No server answered (for example, the local server is not running).
  unreachable,
  timeout,
  http,
  badResponse,

  /// The model stopped (token limit) before writing an answer, for example
  /// after spending every completion token on reasoning.
  truncated,
  missingKey,

  /// The provider has no base URL (for example, no Modal deployment).
  notConfigured,
  budgetExceeded,
  refused,
}

class ModelCallException implements Exception {
  final ModelCallFailure kind;
  final String provider;
  final String message;
  final int? statusCode;
  final int attempts;

  const ModelCallException(
    this.kind,
    this.provider,
    this.message, {
    this.statusCode,
    this.attempts = 1,
  });

  bool get retryable =>
      kind == ModelCallFailure.timeout ||
      (kind == ModelCallFailure.http &&
          (statusCode == 429 || (statusCode ?? 0) >= 500));

  @override
  String toString() => message;
}

/// The JSON body for a chat call, following [provider]'s request style.
///
/// Muse Spark models (meta, baseten, fireworks) always reason: they get
/// `reasoning_effort` (never "none"). meta takes `max_completion_tokens`
/// and never `stop`, `n`, `logit_bias`, penalties, `max_tokens` or a
/// temperature. Muse Glimmer (modal, local) gets Meta's recommended
/// sampling and its reasoning strength as a `Reasoning strength: <value>`
/// line in the system prompt.
Map<String, Object?> chatRequestBody({
  required ProviderConfig provider,
  required String model,
  required List<ChatMessage> messages,
  required int maxTokens,
  String reasoningEffort = 'low',
}) {
  var sent = messages;
  final strength = provider.reasoningStrength;
  if (strength != null) {
    final line = 'Reasoning strength: $strength.';
    sent = messages.isNotEmpty && messages.first.role == 'system'
        ? [
            ChatMessage('system', '$line\n${messages.first.content}'),
            ...messages.skip(1),
          ]
        : [ChatMessage('system', line), ...messages];
  }
  return {
    'model': model,
    'messages': [for (final message in sent) message.toJson()],
    if (provider.sendReasoningEffort)
      'reasoning_effort': reasoningEffort == 'none' ? 'low' : reasoningEffort,
    ...provider.sampling,
    provider.tokenLimitField: maxTokens,
  };
}

/// Remove reasoning text a server left in the answer: Muse Glimmer's
/// `to=self` reasoning channel (when no reasoning parser split it out),
/// `<think>` blocks, and stray channel tokens.
String stripReasoning(String content) {
  var text = content.replaceAll(
    RegExp(
      r'<\|start\|>assistant to=self<\|message\|>[\s\S]*?(<\|eom\|>|<\|end\|>|$)',
    ),
    '',
  );
  text = text.replaceAll(RegExp(r'<think>[\s\S]*?(</think>|$)'), '');
  // A final channel header such as "<|start|>assistant to=user<|message|>".
  text = text.replaceAll(RegExp(r'<\|start\|>assistant[^<]*<\|message\|>'), '');
  text = text.replaceAll(RegExp(r'<\|(eom|end|eot|return)\|>'), '');
  return text.trim();
}

/// One OpenAI-compatible Chat Completions client
/// (`POST {baseUrl}/chat/completions`). API keys are sent only in the
/// Authorization header and never appear in errors or logs.
class ChatClient {
  final int maxRetries;
  final Duration baseDelay;
  final Future<void> Function(Duration) sleep;
  final Random random;
  final void Function(String message) log;

  /// How long a call may go unanswered before a provider's wake notice is
  /// printed.
  final Duration wakeAfter;

  ChatClient({
    this.maxRetries = 3,
    this.baseDelay = const Duration(milliseconds: 500),
    this.wakeAfter = const Duration(seconds: 10),
    Future<void> Function(Duration)? sleep,
    Random? random,
    void Function(String message)? log,
  }) : sleep = sleep ?? Future<void>.delayed,
       random = random ?? Random(),
       log = log ?? ((_) {});

  /// Send [body] to [provider], retrying 429, 5xx and timeouts with
  /// exponential backoff and jitter (honouring Retry-After up to 30 s).
  Future<ChatResult> complete({
    required ProviderConfig provider,
    required Map<String, Object?> body,
    required String? apiKey,
  }) async {
    final stopwatch = Stopwatch()..start();
    // A cold start (for example Modal scaling up from zero) can take
    // minutes; say so once instead of looking hung.
    final notice = provider.wakeNotice;
    final wakeTimer = notice == null
        ? null
        : Timer(wakeAfter, () => log(notice));
    try {
      return await _completeWithRetries(provider, body, apiKey, stopwatch);
    } finally {
      wakeTimer?.cancel();
    }
  }

  Future<ChatResult> _completeWithRetries(
    ProviderConfig provider,
    Map<String, Object?> body,
    String? apiKey,
    Stopwatch stopwatch,
  ) async {
    for (var attempt = 1; ; attempt++) {
      try {
        final response = await _post(
          provider,
          '/chat/completions',
          body,
          apiKey,
        );
        return _parse(
          provider,
          body['model'] as String,
          response,
          stopwatch.elapsed,
          attempt,
        );
      } on _RetryAfter catch (signal) {
        final error = signal.error;
        if (!error.retryable || attempt > maxRetries) {
          throw ModelCallException(
            error.kind,
            error.provider,
            '${error.message} (after $attempt attempt${attempt == 1 ? '' : 's'})',
            statusCode: error.statusCode,
            attempts: attempt,
          );
        }
        final backoff = baseDelay * pow(2, attempt - 1).toInt();
        final jitter = Duration(
          milliseconds: random.nextInt(baseDelay.inMilliseconds + 1),
        );
        var delay = backoff + jitter;
        if (signal.retryAfter != null && signal.retryAfter! > delay) {
          delay = signal.retryAfter!;
        }
        if (delay > const Duration(seconds: 30)) {
          delay = const Duration(seconds: 30);
        }
        log(
          '${provider.id}: ${error.message}; retry $attempt of $maxRetries in ${delay.inMilliseconds} ms',
        );
        await sleep(delay);
      }
    }
  }

  /// `GET {baseUrl}/models`: the model IDs the provider lists.
  Future<List<String>> listModels(
    ProviderConfig provider,
    String? apiKey,
  ) async {
    final Map<String, Object?> response;
    try {
      response = await _send(provider, 'GET', '/models', null, apiKey);
    } on _RetryAfter catch (signal) {
      throw signal.error;
    }
    final data = response['data'];
    if (data is! List) {
      throw ModelCallException(
        ModelCallFailure.badResponse,
        provider.id,
        '${provider.id}: /models returned no data list',
      );
    }
    return [
      for (final item in data)
        if (item is Map && item['id'] is String) item['id'] as String,
    ]..sort();
  }

  Future<Map<String, Object?>> _post(
    ProviderConfig provider,
    String path,
    Map<String, Object?> body,
    String? apiKey,
  ) => _send(provider, 'POST', path, body, apiKey);

  Future<Map<String, Object?>> _send(
    ProviderConfig provider,
    String method,
    String path,
    Map<String, Object?>? body,
    String? apiKey,
  ) async {
    final uri = Uri.parse(
      '${provider.baseUrl.replaceAll(RegExp(r'/+$'), '')}$path',
    );
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    String scrub(String text) => apiKey == null || apiKey.isEmpty
        ? text
        : text.replaceAll(apiKey, '[key]');
    try {
      final request = await client
          .openUrl(method, uri)
          .timeout(provider.timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (apiKey != null && apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(jsonEncode(body)));
      }
      final response = await request.close().timeout(provider.timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(provider.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final retryAfter = int.tryParse(
          response.headers.value('retry-after') ?? '',
        );
        final detail = scrub(text.trim());
        throw _RetryAfter(
          ModelCallException(
            ModelCallFailure.http,
            provider.id,
            '${provider.id}: HTTP ${response.statusCode}${detail.isEmpty ? '' : ': ${detail.length > 300 ? '${detail.substring(0, 300)}…' : detail}'}',
            statusCode: response.statusCode,
          ),
          retryAfter == null ? null : Duration(seconds: retryAfter),
        );
      }
      try {
        return (jsonDecode(text) as Map).cast<String, Object?>();
      } on FormatException {
        throw ModelCallException(
          ModelCallFailure.badResponse,
          provider.id,
          '${provider.id}: the response was not JSON',
        );
      }
    } on TimeoutException {
      throw _RetryAfter(
        ModelCallException(
          ModelCallFailure.timeout,
          provider.id,
          '${provider.id}: no response within ${provider.timeout.inSeconds} s',
        ),
      );
    } on SocketException catch (error) {
      throw ModelCallException(
        ModelCallFailure.unreachable,
        provider.id,
        '${provider.id}: no server answered at ${provider.baseUrl} (${scrub(error.osError?.message ?? error.message)})',
      );
    } on HttpException catch (error) {
      throw _RetryAfter(
        ModelCallException(
          ModelCallFailure.http,
          provider.id,
          '${provider.id}: ${scrub(error.message)}',
          statusCode: 503,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  ChatResult _parse(
    ProviderConfig provider,
    String model,
    Map<String, Object?> json,
    Duration latency,
    int attempts,
  ) {
    final choices = json['choices'];
    final message =
        choices is List && choices.isNotEmpty && choices.first is Map
        ? (choices.first as Map)['message']
        : null;
    if (message is! Map) {
      throw ModelCallException(
        ModelCallFailure.badResponse,
        provider.id,
        '${provider.id}: the response had no message',
      );
    }
    // Reasoning models may stop before writing any content; the caller
    // decides what to do with an empty answer (its tokens were billed).
    final content = message['content'];
    final usage = json['usage'] is Map ? json['usage'] as Map : const {};
    return ChatResult(
      content: content is String ? stripReasoning(content) : '',
      finishReason: (choices as List).first is Map
          ? ((choices.first as Map)['finish_reason'] as String?)
          : null,
      provider: provider.id,
      model: json['model'] as String? ?? model,
      promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
      latency: latency,
      attempts: attempts,
    );
  }
}

/// A failed attempt that [ChatClient.complete] may retry.
class _RetryAfter implements Exception {
  final ModelCallException error;
  final Duration? retryAfter;

  const _RetryAfter(this.error, [this.retryAfter]);
}
