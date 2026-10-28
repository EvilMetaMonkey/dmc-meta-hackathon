import 'dart:convert';
import 'dart:io';

/// One recorded request to a [FakeProvider].
class FakeRequest {
  final String method;
  final String path;
  final String? authorization;
  final Map<String, Object?>? body;

  const FakeRequest(this.method, this.path, this.authorization, this.body);
}

/// A canned reply.
class FakeReply {
  final int status;
  final Object? json;
  final Map<String, String> headers;

  const FakeReply(this.status, this.json, {this.headers = const {}});

  /// A successful chat completion.
  factory FakeReply.chat(
    String content, {
    String? reasoning,
    int prompt = 11,
    int completion = 7,
    String model = 'fake-model',
  }) => FakeReply(200, {
    'id': 'chatcmpl-1',
    'model': model,
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content': content,
          'reasoning_content': ?reasoning,
        },
        'finish_reason': 'stop',
      },
    ],
    'usage': {'prompt_tokens': prompt, 'completion_tokens': completion},
  });
}

/// A local HTTP server that plays an OpenAI-compatible provider. Replies are
/// served in order; the last one repeats.
class FakeProvider {
  final HttpServer _server;
  final List<FakeReply> replies;
  final List<FakeRequest> requests = [];

  /// How long each reply waits, to imitate a cold start.
  final Duration delay;

  FakeProvider._(this._server, this.replies, this.delay);

  static Future<FakeProvider> start(
    List<FakeReply> replies, {
    Duration delay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeProvider._(server, replies, delay);
    server.listen(fake._handle);
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> _handle(HttpRequest request) async {
    final text = await utf8.decoder.bind(request).join();
    requests.add(
      FakeRequest(
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
        text.isEmpty ? null : (jsonDecode(text) as Map).cast<String, Object?>(),
      ),
    );
    final reply =
        replies[requests.length - 1 < replies.length
            ? requests.length - 1
            : replies.length - 1];
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    request.response.statusCode = reply.status;
    reply.headers.forEach(request.response.headers.set);
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply.json));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// A base URL where nothing listens.
Future<String> closedBaseUrl() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return 'http://127.0.0.1:$port/v1';
}
