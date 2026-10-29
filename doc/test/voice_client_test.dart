import 'package:dmc_doc/doc.dart';
import 'package:test/test.dart';

import 'support/fake_voice.dart';

void main() {
  const key = 'LLM|voice-key-for-tests-01';

  Future<TranscriptionResult> run(
    FakeVoiceServer server, {
    double seconds = 0.5,
    List<String>? partialsSeen,
    TranscriptionCancel? cancel,
    List<String> keywords = const [],
  }) {
    final audio = pcmSeconds(seconds);
    return const MetaRealtimeTranscriber().transcribe(
      baseUrl: server.baseUrl,
      apiKey: key,
      model: metaVoiceModel,
      sampleRate: 16000,
      audio: pacedFrames(audio, 16000),
      onPartial: partialsSeen?.add,
      cancel: cancel,
      keywords: keywords,
    );
  }

  test('the realtime URL follows the provider base URL', () {
    expect(
      realtimeUri('https://api.meta.ai/v1', sessionId: 's1').toString(),
      'wss://api.meta.ai/v1/asr/realtime?sessionId=s1',
    );
    expect(
      realtimeUri('http://127.0.0.1:9/v1/').toString(),
      'ws://127.0.0.1:9/v1/asr/realtime',
    );
    expect(audioEncodingFor(16000), 'PCM_16KHZ');
    expect(audioEncodingFor(24000), 'PCM_24KHZ');
    expect(() => audioEncodingFor(44100), throwsArgumentError);
  });

  test('handshake, paced binary frames of at most 4 s, endStream, partials '
      'and the final transcript', () async {
    final server = await FakeVoiceServer.start(
      partials: ['take', 'take me', 'take me back'],
      finalTranscript: 'take me back to before it touched auth.',
    );
    addTearDown(server.close);
    final partials = <String>[];
    final result = await run(
      server,
      partialsSeen: partials,
      keywords: ['auth', 'dmc'],
    );

    // The handshake carries the key; the HTTP header is not used.
    final handshake = server.handshakes.single;
    expect(handshake['authorization'], {'accessToken': 'Bearer $key'});
    expect(handshake['audioEncoding'], 'PCM_16KHZ');
    expect(handshake['model'], 'muse-voice-transcribe-1.0');
    expect(handshake['mode'], 'PUSH_TO_TALK');
    expect(handshake['partialMode'], 'CUMULATIVE');
    expect(handshake['keywords'], ['auth', 'dmc']);

    // 0.5 s in 80 ms frames: 7 binary frames, none over 4 s of audio.
    expect(server.frames, hasLength(7));
    for (final frame in server.frames) {
      expect(frame.bytes, lessThanOrEqualTo(16000 * 2 * 4));
      expect(frame.bytes, lessThanOrEqualTo(2560));
    }
    expect(server.audioBytes, 16000);
    // Paced in real time: the last frame left about 6 × 80 ms after the first.
    final span = server.frames.last.at - server.frames.first.at;
    expect(span.inMilliseconds, greaterThanOrEqualTo(400));
    expect(server.endStreams, 1);
    expect(server.textFrames, [
      {'type': 'endStream'},
    ]);

    expect(partials, ['take', 'take me', 'take me back']);
    expect(result.transcript, 'take me back to before it touched auth.');
    expect(result.sessionId, 'fake-session-1');
    expect(result.audioProcessedMs, 500);
    expect(result.billedSeconds, 0);
    expect(result.audioSent.inMilliseconds, 500);
    expect(result.cancelled, isFalse);
  });

  test('an error event fails the turn with its message', () async {
    final server = await FakeVoiceServer.start(mode: FakeVoiceMode.error);
    addTearDown(server.close);
    await expectLater(
      run(server),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.kind, 'kind', TranscriptionFailure.server)
            .having((e) => e.message, 'message', contains('Unsupported audio'))
            .having((e) => e.message, 'no key', isNot(contains(key))),
      ),
    );
  });

  test('a 1008 close is reported as a pacing or request problem', () async {
    final server = await FakeVoiceServer.start(mode: FakeVoiceMode.policy);
    addTearDown(server.close);
    await expectLater(
      run(server),
      throwsA(
        isA<TranscriptionException>()
            .having((e) => e.kind, 'kind', TranscriptionFailure.policy)
            .having((e) => e.closeCode, 'code', 1008)
            .having((e) => e.message, 'message', contains('real time')),
      ),
    );
  });

  test('a refused handshake is reported', () async {
    final server = await FakeVoiceServer.start(
      mode: FakeVoiceMode.refuseHandshake,
    );
    addTearDown(server.close);
    await expectLater(
      run(server),
      throwsA(
        isA<TranscriptionException>().having(
          (e) => e.kind,
          'kind',
          TranscriptionFailure.handshake,
        ),
      ),
    );
    expect(server.frames, isEmpty);
  });

  test('cancel sends nothing more: no further audio, no endStream', () async {
    final server = await FakeVoiceServer.start(finalTranscript: 'never');
    addTearDown(server.close);
    final cancel = TranscriptionCancel();
    final turn = run(server, seconds: 2, cancel: cancel);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    cancel.cancel();
    final result = await turn;
    await server.closed.future.timeout(const Duration(seconds: 5));
    expect(result.cancelled, isTrue);
    expect(server.endStreams, 0);
    expect(server.audioBytes, lessThan(16000 * 2 * 2));
  });

  test('WAV files: PCM16 mono 16/24 kHz is read directly', () {
    final samples = pcmSeconds(0.1);
    final wav = pcmWav(samples, 16000);
    final read = readPcmWav(wav)!;
    expect(read.sampleRate, 16000);
    expect(read.bytes, samples);
    expect(readPcmWav(pcmWav(samples, 24000))!.sampleRate, 24000);
    expect(readPcmWav(pcmWav(samples, 44100)), isNull);
  });
}
