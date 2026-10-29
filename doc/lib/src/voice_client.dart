import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Muse Voice Transcribe over Meta's realtime WebSocket
/// (`wss://api.meta.ai/v1/asr/realtime`), as documented at
/// dev.meta.ai/docs/api-reference/voice/realtime (checked 2026-10-28):
///
/// - The first text frame is the handshake, sent within 10 s:
///   `{"authorization": {"accessToken": "Bearer KEY"}, "audioEncoding":
///   "PCM_16KHZ" | "PCM_24KHZ", "model": ..., "mode": "PUSH_TO_TALK",
///   "partialMode": "CUMULATIVE"}`. The HTTP Authorization header is
///   ignored. The reply is `{"sessionId": ...}`, the only frame without a
///   `type`.
/// - Audio is raw signed 16-bit little-endian mono PCM in binary frames,
///   paced in real time (the docs' example sends 80 ms frames). A backlog
///   or below-real-time ingress closes the socket with 1008.
/// - `{"type": "endStream"}` ends input (push-to-talk has no other commit);
///   the server then sends the rest and closes with 1000.
/// - Events: `transcript` (`transcript`, `final`, `audioProcessedMs`; with
///   CUMULATIVE each partial replaces the last, and `final: true` marks
///   completion in PUSH_TO_TALK), `audioProgress` (`audioProcessedMs`),
///   `speechStart`/`speechEnd`/`speechComplete`/`speaker`, and `error`
///   (`message`, `sessionId`, optional `errorType`, `errorCode`,
///   `errorParam`), sent just before the server closes.
/// - Close codes: 1000 normal, 1008 invalid request or pacing, 1011 server
///   failure, 1013 rate limited.

/// Frame length Doc sends, as in Meta's example.
const Duration voiceFrameDuration = Duration(milliseconds: 80);

/// The `audioEncoding` handshake value for [sampleRate].
String audioEncodingFor(int sampleRate) => switch (sampleRate) {
  16000 => 'PCM_16KHZ',
  24000 => 'PCM_24KHZ',
  _ => throw ArgumentError(
    'Muse Voice Transcribe takes 16 or 24 kHz audio, not $sampleRate Hz.',
  ),
};

/// Bytes of PCM16 mono audio in [duration] at [sampleRate].
int pcmBytesFor(Duration duration, int sampleRate) =>
    sampleRate * 2 * duration.inMicroseconds ~/ Duration.microsecondsPerSecond;

/// The realtime URL for a provider base URL such as
/// `https://api.meta.ai/v1` (→ `wss://api.meta.ai/v1/asr/realtime`).
Uri realtimeUri(String baseUrl, {String? sessionId}) {
  final base = Uri.parse(baseUrl.replaceAll(RegExp(r'/+$'), ''));
  return base.replace(
    scheme: base.scheme == 'http' ? 'ws' : 'wss',
    path: '${base.path}/asr/realtime',
    queryParameters: sessionId == null ? null : {'sessionId': sessionId},
  );
}

enum TranscriptionFailure {
  unreachable,
  handshake,

  /// Meta's `error` event.
  server,

  /// 1008: an invalid request or audio that fell behind real time.
  policy,
  rateLimited,
  closed,
  timeout,
}

class TranscriptionException implements Exception {
  final TranscriptionFailure kind;
  final String message;
  final int? closeCode;

  const TranscriptionException(this.kind, this.message, {this.closeCode});

  @override
  String toString() => message;
}

/// What one push-to-talk turn produced.
class TranscriptionResult {
  final String transcript;
  final String? sessionId;

  /// The highest `audioProcessedMs` the server reported: the audio it
  /// processed, which is what Meta bills (whole seconds, rounded down).
  final int audioProcessedMs;

  /// Bytes of audio Doc sent, and how long they represent.
  final int audioBytesSent;
  final Duration audioSent;

  /// From sending `endStream` to the final transcript.
  final Duration finalLatency;

  /// The number of partial transcripts received.
  final int partials;

  /// The user cancelled; [transcript] is whatever partial was seen.
  final bool cancelled;

  const TranscriptionResult({
    required this.transcript,
    required this.sessionId,
    required this.audioProcessedMs,
    required this.audioBytesSent,
    required this.audioSent,
    required this.finalLatency,
    required this.partials,
    this.cancelled = false,
  });

  /// Billed seconds: whole seconds of processed audio, rounded down.
  int get billedSeconds => audioProcessedMs ~/ 1000;
}

/// Lets a caller stop a turn early and send nothing more.
class TranscriptionCancel {
  final Completer<void> _done = Completer<void>();

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  bool get isCancelled => _done.isCompleted;
  Future<void> get future => _done.future;
}

/// Speech to text for one push-to-talk turn. The audio stream must already
/// be paced in real time; it ends when the user stops talking.
abstract class TranscriptionClient {
  Future<TranscriptionResult> transcribe({
    required String baseUrl,
    required String apiKey,
    required String model,
    required int sampleRate,
    required Stream<List<int>> audio,
    void Function(String partial)? onPartial,
    TranscriptionCancel? cancel,
    List<String> keywords = const [],
  });
}

/// The real client, on `dart:io`'s WebSocket.
class MetaRealtimeTranscriber implements TranscriptionClient {
  final Duration handshakeTimeout;

  /// How long to wait for the final transcript after `endStream`.
  final Duration finalTimeout;

  const MetaRealtimeTranscriber({
    this.handshakeTimeout = const Duration(seconds: 10),
    this.finalTimeout = const Duration(seconds: 30),
  });

  @override
  Future<TranscriptionResult> transcribe({
    required String baseUrl,
    required String apiKey,
    required String model,
    required int sampleRate,
    required Stream<List<int>> audio,
    void Function(String partial)? onPartial,
    TranscriptionCancel? cancel,
    List<String> keywords = const [],
  }) async {
    String scrub(String text) => text.replaceAll(apiKey, '[key]');
    final sessionId =
        'doc-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(1 << 32).toRadixString(16)}';
    final uri = realtimeUri(baseUrl, sessionId: sessionId);
    final WebSocket socket;
    try {
      socket = await WebSocket.connect(
        uri.toString(),
      ).timeout(handshakeTimeout);
    } on TimeoutException {
      throw TranscriptionException(
        TranscriptionFailure.timeout,
        'voice: no connection to ${uri.replace(query: '')} within ${handshakeTimeout.inSeconds} s',
      );
    } on Object catch (error) {
      throw TranscriptionException(
        TranscriptionFailure.unreachable,
        'voice: could not connect to ${uri.replace(query: '')}: ${scrub('$error')}',
      );
    }

    final handshakeDone = Completer<String?>();
    final finished = Completer<void>();
    TranscriptionException? failure;
    var transcript = '';
    String? finalTranscript;
    var processedMs = 0;
    var partials = 0;
    String? acknowledged;
    var handshakeOk = false;

    void fail(TranscriptionException error) {
      failure ??= error;
      if (!handshakeDone.isCompleted) handshakeDone.complete(null);
      if (!finished.isCompleted) finished.complete();
    }

    final subscription = socket.listen(
      (message) {
        if (message is! String) return;
        final Object? event;
        try {
          event = jsonDecode(message);
        } on FormatException {
          return;
        }
        if (event is! Map) return;
        final type = event['type'];
        if (type == null) {
          final id = event['sessionId'];
          if (id is String) handshakeOk = true;
          if (!handshakeDone.isCompleted) {
            handshakeDone.complete(id is String ? id : null);
          }
          return;
        }
        final ms = event['audioProcessedMs'];
        if (ms is num && ms.toInt() > processedMs) processedMs = ms.toInt();
        switch (type) {
          case 'transcript':
            final text = event['transcript'];
            if (text is! String) return;
            // CUMULATIVE: each partial replaces the previous one.
            transcript = text;
            if (event['final'] == true) {
              finalTranscript = text;
              if (!finished.isCompleted) finished.complete();
            } else {
              partials++;
              onPartial?.call(text);
            }
          case 'speechComplete':
            final text = event['transcript'];
            if (text is String) transcript = text;
          case 'error':
            fail(
              TranscriptionException(
                TranscriptionFailure.server,
                'voice: Meta reported an error: ${scrub('${event['message']}')}'
                '${event['errorCode'] == null ? '' : ' (${event['errorCode']})'}',
              ),
            );
        }
      },
      onDone: () {
        final code = socket.closeCode;
        if (!handshakeOk) {
          fail(
            TranscriptionException(
              TranscriptionFailure.handshake,
              'voice: Meta refused the handshake${code == null ? '' : ' ($code${socket.closeReason == null || socket.closeReason!.isEmpty ? '' : ': ${socket.closeReason}'})'}',
              closeCode: code,
            ),
          );
        } else if (code != null && code != 1000) {
          fail(_closed(code, socket.closeReason));
        }
        if (!finished.isCompleted) finished.complete();
      },
      onError: (Object error) => fail(
        TranscriptionException(
          TranscriptionFailure.closed,
          'voice: the connection failed: ${scrub('$error')}',
        ),
      ),
    );

    var bytesSent = 0;
    try {
      socket.add(
        jsonEncode({
          'authorization': {'accessToken': 'Bearer $apiKey'},
          'audioEncoding': audioEncodingFor(sampleRate),
          'model': model,
          'mode': 'PUSH_TO_TALK',
          'partialMode': 'CUMULATIVE',
          if (keywords.isNotEmpty) 'keywords': keywords,
        }),
      );
      try {
        acknowledged = await handshakeDone.future.timeout(handshakeTimeout);
      } on TimeoutException {
        throw TranscriptionException(
          TranscriptionFailure.handshake,
          'voice: Meta did not acknowledge the handshake within ${handshakeTimeout.inSeconds} s',
        );
      }
      if (failure != null) throw failure!;
      if (acknowledged == null) {
        throw const TranscriptionException(
          TranscriptionFailure.handshake,
          'voice: the handshake was refused (no sessionId in the reply)',
        );
      }

      // Stream the (already paced) audio until it ends, fails or is
      // cancelled.
      final streamed = Completer<void>();
      late final StreamSubscription<List<int>> audioSubscription;
      audioSubscription = audio.listen(
        (chunk) {
          if (failure != null || (cancel?.isCancelled ?? false)) return;
          socket.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
          bytesSent += chunk.length;
        },
        onDone: () {
          if (!streamed.isCompleted) streamed.complete();
        },
        onError: (Object error) {
          fail(
            TranscriptionException(
              TranscriptionFailure.closed,
              'voice: the audio source failed: $error',
            ),
          );
          if (!streamed.isCompleted) streamed.complete();
        },
      );
      await Future.any([
        streamed.future,
        finished.future,
        if (cancel != null) cancel.future,
      ]);
      await audioSubscription.cancel();
      if (failure != null) throw failure!;
      if (cancel?.isCancelled ?? false) {
        // Send nothing more: close without endStream.
        await socket.close(1000, 'cancelled');
        return TranscriptionResult(
          transcript: transcript,
          sessionId: acknowledged,
          audioProcessedMs: processedMs,
          audioBytesSent: bytesSent,
          audioSent: _duration(bytesSent, sampleRate),
          finalLatency: Duration.zero,
          partials: partials,
          cancelled: true,
        );
      }

      final stopwatch = Stopwatch()..start();
      if (!finished.isCompleted) {
        socket.add(jsonEncode({'type': 'endStream'}));
        try {
          await finished.future.timeout(finalTimeout);
        } on TimeoutException {
          throw TranscriptionException(
            TranscriptionFailure.timeout,
            'voice: no final transcript within ${finalTimeout.inSeconds} s of the end of the audio',
          );
        }
      }
      final latency = stopwatch.elapsed;
      if (failure != null) throw failure!;
      return TranscriptionResult(
        transcript: (finalTranscript ?? transcript).trim(),
        sessionId: acknowledged,
        audioProcessedMs: processedMs,
        audioBytesSent: bytesSent,
        audioSent: _duration(bytesSent, sampleRate),
        finalLatency: latency,
        partials: partials,
      );
    } finally {
      await subscription.cancel();
      if (socket.readyState == WebSocket.open) {
        await socket.close(1000);
      }
    }
  }

  static Duration _duration(int bytes, int sampleRate) => Duration(
    microseconds: bytes * Duration.microsecondsPerSecond ~/ (sampleRate * 2),
  );

  static TranscriptionException _closed(int code, String? reason) {
    final why = reason == null || reason.isEmpty ? '' : ': $reason';
    return switch (code) {
      1008 => TranscriptionException(
        TranscriptionFailure.policy,
        'voice: Meta closed the stream (1008, invalid request or audio not paced in real time$why)',
        closeCode: code,
      ),
      1013 => TranscriptionException(
        TranscriptionFailure.rateLimited,
        'voice: rate limited by Meta (1013$why); wait and try again',
        closeCode: code,
      ),
      _ => TranscriptionException(
        TranscriptionFailure.closed,
        'voice: Meta closed the stream ($code$why)',
        closeCode: code,
      ),
    };
  }
}

/// [pcm] as [voiceFrameDuration] frames, released at real-time pace:
/// frame n leaves at n × 80 ms after the first, measured from one start
/// time so delays never accumulate.
Stream<List<int>> pacedFrames(
  List<int> pcm,
  int sampleRate, {
  Duration frame = voiceFrameDuration,
  Future<void> Function(Duration)? sleep,
}) async* {
  final size = pcmBytesFor(frame, sampleRate);
  final wait = sleep ?? Future<void>.delayed;
  final clock = Stopwatch()..start();
  var index = 0;
  for (var offset = 0; offset < pcm.length; offset += size) {
    final due = frame * index;
    final ahead = due - clock.elapsed;
    if (ahead > Duration.zero) await wait(ahead);
    yield pcm.sublist(offset, min(offset + size, pcm.length));
    index++;
  }
}

/// Regroup a live byte stream (a microphone's stdout) into frames of
/// [voiceFrameDuration]; the source already runs in real time.
Stream<List<int>> framed(Stream<List<int>> source, int sampleRate) async* {
  final size = pcmBytesFor(voiceFrameDuration, sampleRate);
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in source) {
    buffer.add(chunk);
    while (buffer.length >= size) {
      final bytes = buffer.takeBytes();
      yield bytes.sublist(0, size);
      if (bytes.length > size) buffer.add(bytes.sublist(size));
    }
  }
  if (buffer.isNotEmpty) yield buffer.takeBytes();
}

/// PCM16 mono audio with its sample rate.
class PcmAudio {
  final Uint8List bytes;
  final int sampleRate;

  const PcmAudio(this.bytes, this.sampleRate);

  Duration get duration => Duration(
    microseconds:
        bytes.length * Duration.microsecondsPerSecond ~/ (sampleRate * 2),
  );
}

/// The samples of a WAV file that is already PCM16 mono at 16 or 24 kHz,
/// or null when it needs converting.
PcmAudio? readPcmWav(Uint8List data) {
  if (data.length < 12 ||
      ascii.decode(data.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
      ascii.decode(data.sublist(8, 12), allowInvalid: true) != 'WAVE') {
    return null;
  }
  final view = ByteData.sublistView(data);
  int? format, channels, rate, bits;
  var offset = 12;
  while (offset + 8 <= data.length) {
    final id = ascii.decode(
      data.sublist(offset, offset + 4),
      allowInvalid: true,
    );
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;
    if (id == 'fmt ' && body + 16 <= data.length) {
      format = view.getUint16(body, Endian.little);
      channels = view.getUint16(body + 2, Endian.little);
      rate = view.getUint32(body + 4, Endian.little);
      bits = view.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      if (format != 1 || channels != 1 || bits != 16) return null;
      if (rate != 16000 && rate != 24000) return null;
      final end = min(body + size, data.length);
      return PcmAudio(Uint8List.sublistView(data, body, end), rate!);
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// A WAV file of PCM16 mono [samples] (for tests and demos).
Uint8List pcmWav(Uint8List samples, int sampleRate) {
  final header = ByteData(44);
  void text(int at, String value) {
    for (var i = 0; i < value.length; i++) {
      header.setUint8(at + i, value.codeUnitAt(i));
    }
  }

  text(0, 'RIFF');
  header.setUint32(4, 36 + samples.length, Endian.little);
  text(8, 'WAVE');
  text(12, 'fmt ');
  header
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, 1, Endian.little)
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  text(36, 'data');
  header.setUint32(40, samples.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...samples]);
}
