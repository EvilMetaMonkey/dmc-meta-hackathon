import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'fake_provider.dart';

/// How the fake realtime server behaves after the handshake.
enum FakeVoiceMode {
  /// Partials as frames arrive, the final transcript on endStream, close 1000.
  normal,

  /// An `error` event after the first frame, then close 1011.
  error,

  /// Close 1008 after the first frame (as for audio that falls behind).
  policy,

  /// A handshake reply without a sessionId, then close 1008.
  refuseHandshake,
}

/// One binary frame the fake received, and when.
class FakeVoiceFrame {
  final int bytes;
  final Duration at;
  const FakeVoiceFrame(this.bytes, this.at);
}

/// A local server that plays Meta's realtime transcription WebSocket at
/// `/v1/asr/realtime`, and also answers `/v1/chat/completions` (the
/// restore role uses the same Meta base URL) with [chatReplies] in order.
class FakeVoiceServer {
  final HttpServer _server;
  final FakeVoiceMode mode;
  final List<String> partials;
  final String finalTranscript;
  final List<FakeReply> chatReplies;
  final List<FakeRequest> chatRequests = [];

  /// The first text frame of each session.
  final List<Map<String, Object?>> handshakes = [];
  final List<FakeVoiceFrame> frames = [];
  final List<Object?> textFrames = [];
  var sessions = 0;
  var endStreams = 0;
  final Completer<void> closed = Completer<void>();

  FakeVoiceServer._(
    this._server,
    this.mode,
    this.partials,
    this.finalTranscript,
    this.chatReplies,
  );

  static Future<FakeVoiceServer> start({
    FakeVoiceMode mode = FakeVoiceMode.normal,
    List<String> partials = const [],
    String finalTranscript = '',
    List<FakeReply> chatReplies = const [],
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeVoiceServer._(
      server,
      mode,
      partials,
      finalTranscript,
      chatReplies,
    );
    server.listen(fake._handle);
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  int get audioBytes => frames.fold(0, (sum, f) => sum + f.bytes);

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/v1/asr/realtime' &&
        WebSocketTransformer.isUpgradeRequest(request)) {
      await _session(await WebSocketTransformer.upgrade(request));
      return;
    }
    final text = await utf8.decoder.bind(request).join();
    chatRequests.add(
      FakeRequest(
        request.method,
        request.uri.path,
        request.headers.value(HttpHeaders.authorizationHeader),
        text.isEmpty ? null : (jsonDecode(text) as Map).cast<String, Object?>(),
      ),
    );
    final reply = chatReplies.isEmpty
        ? const FakeReply(404, {'error': 'no reply'})
        : chatReplies[chatRequests.length - 1 < chatReplies.length
              ? chatRequests.length - 1
              : chatReplies.length - 1];
    request.response.statusCode = reply.status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(reply.json));
    await request.response.close();
  }

  Future<void> _session(WebSocket socket) async {
    sessions++;
    final clock = Stopwatch()..start();
    var handshaken = false;
    var received = 0;
    var bytes = 0;
    int processedMs() => bytes ~/ 32; // 16 kHz PCM16: 32 bytes per ms.
    await for (final message in socket) {
      if (!handshaken) {
        handshakes.add((jsonDecode(message as String) as Map).cast());
        handshaken = true;
        if (mode == FakeVoiceMode.refuseHandshake) {
          socket.add(jsonEncode({'error': 'bad handshake'}));
          await socket.close(1008, 'invalid handshake');
          break;
        }
        socket.add(jsonEncode({'sessionId': 'fake-session-1'}));
        continue;
      }
      if (message is String) {
        final event = jsonDecode(message);
        textFrames.add(event);
        if (event is Map && event['type'] == 'endStream') {
          endStreams++;
          socket.add(
            jsonEncode({
              'type': 'transcript',
              'transcript': finalTranscript,
              'final': true,
              'audioProcessedMs': processedMs(),
            }),
          );
          await socket.close(1000);
          break;
        }
        continue;
      }
      final data = message as Uint8List;
      frames.add(FakeVoiceFrame(data.length, clock.elapsed));
      bytes += data.length;
      received++;
      if (received == 1 && mode == FakeVoiceMode.error) {
        socket.add(
          jsonEncode({
            'type': 'error',
            'message': 'Unsupported audio',
            'sessionId': 'fake-session-1',
            'errorCode': 'bad_audio',
          }),
        );
        await socket.close(1011, 'error');
        break;
      }
      if (received == 1 && mode == FakeVoiceMode.policy) {
        await socket.close(1008, 'Audio fell behind real time');
        break;
      }
      socket.add(
        jsonEncode({
          'type': 'audioProgress',
          'audioProcessedMs': processedMs(),
        }),
      );
      if (received - 1 < partials.length) {
        socket.add(
          jsonEncode({
            'type': 'transcript',
            'transcript': partials[received - 1],
            'final': false,
            'audioProcessedMs': processedMs(),
          }),
        );
      }
    }
    if (!closed.isCompleted) closed.complete();
  }

  Future<void> close() => _server.close(force: true);
}

/// [seconds] of 16 kHz PCM16 mono audio (a quiet tone).
Uint8List pcmSeconds(double seconds, {int sampleRate = 16000}) {
  final samples = (seconds * sampleRate).round();
  final data = ByteData(samples * 2);
  for (var i = 0; i < samples; i++) {
    data.setInt16(i * 2, ((i % 40) - 20) * 50, Endian.little);
  }
  return data.buffer.asUint8List();
}
