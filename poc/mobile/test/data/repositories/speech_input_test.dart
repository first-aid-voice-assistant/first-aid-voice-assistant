import 'dart:typed_data';

import 'package:first_aid_voice_assistant/data/repositories/speech_input.dart';
import 'package:first_aid_voice_assistant/data/services/speech_segmenter.dart';
import 'package:first_aid_voice_assistant/domain/models/speech_engine.dart';
import 'package:first_aid_voice_assistant/domain/models/utterance.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/services.dart';

/// 0.1 s of 16-bit mono audio at 16 kHz.
Uint8List chunk() => Uint8List(3200);

void main() {
  final startedAt = DateTime(2026, 10, 27, 14, 21, 0);

  group('SegmentedSpeechInput', () {
    late FakeVoiceRecorder recorder;
    late FakeSegmentDecoder decoder;
    late FakeSpeechSegmenter segmenter;
    late FakeModelStore store;
    late DateTime now;

    SegmentedSpeechInput input() => SegmentedSpeechInput(
      engine: SpeechEngine.whisperBase,
      store: store,
      recorder: recorder,
      segmenter: segmenter,
      decoder: decoder,
      partialInterval: Duration.zero,
      clock: () => now,
    );

    Future<void> speak(int chunks) async {
      for (var i = 0; i < chunks; i++) {
        recorder.audio.add(chunk());
        await pumpEventQueue();
      }
    }

    setUp(() {
      now = startedAt;
      recorder = FakeVoiceRecorder();
      decoder = FakeSegmentDecoder();
      segmenter = FakeSpeechSegmenter(
        speech: const [SpeechRegion(1600, 9600), SpeechRegion(12800, 20800)],
      );
      store = FakeModelStore({});
    });

    test(
      'speech heard while muted is dropped, speech after it is kept',
      () async {
        final speech = input();
        await speech.prepare();
        final partials = <String>[];
        final utterances = <Utterance>[];
        speech.partialText.listen(partials.add);
        speech.utterances.listen(utterances.add);

        await speech.start();
        await speak(3);
        speech.muted = true;
        await speak(4);
        expect(partials.last, isEmpty);
        speech.muted = false;
        await speak(7);
        await speech.finish();

        expect(utterances, hasLength(1));
        expect(
          utterances.single.endedAt,
          startedAt.add(const Duration(milliseconds: 1300)),
        );
      },
    );

    test('prepare downloads the engine and loads both models', () async {
      final speech = input();

      await speech.prepare();

      expect(store.downloaded, contains(SpeechEngine.whisperBase));
      expect(decoder.loadedFrom, 'models');
      expect(segmenter.loadedFrom, 'models/${SpeechEngine.vadModelPath}');
      expect(decoder.decodedLengths, [16000]);
      expect(speech.label, 'Whisper base');
    });

    test('start before prepare is rejected', () async {
      await expectLater(input().start(), throwsA(isA<SpeechInputException>()));
    });

    test('each region is a separate utterance with its own time', () async {
      final speech = input();
      await speech.prepare();
      final utterances = <Utterance>[];
      speech.utterances.listen(utterances.add);

      await speech.start();
      await speak(11);
      await speech.finish();

      expect(utterances.map((u) => u.text), ['n8000', 'n4800']);
      final first = utterances.first;
      expect(first.endedAt, startedAt.add(const Duration(milliseconds: 600)));
      expect(first.speechDuration, const Duration(milliseconds: 500));
      expect(utterances.last.speechDuration, const Duration(milliseconds: 300));
      expect(recorder.streaming, isFalse);
    });

    test('decodes only speech, never the silence around it', () async {
      final speech = input();
      await speech.prepare();
      decoder.decodedLengths.clear();

      await speech.start();
      await speak(11);
      await speech.finish();

      expect(decoder.decodedLengths.every((n) => n <= 8000), isTrue);
      expect(decoder.decodedLengths, contains(8000));
      expect(decoder.decodedLengths.last, 4800);
    });

    test('shows the partial text of the speech in progress', () async {
      final speech = input();
      await speech.prepare();
      final partials = <String>[];
      speech.partialText.listen(partials.add);

      await speech.start();
      await speak(5);

      expect(partials, isNotEmpty);
      expect(partials.last, 'n6400');
      await speech.cancel();
    });

    test('cancel stops recording without utterances', () async {
      final speech = input();
      await speech.prepare();
      final utterances = <Utterance>[];
      speech.utterances.listen(utterances.add);

      await speech.start();
      await speak(5);
      await speech.cancel();

      expect(recorder.streaming, isFalse);
      expect(utterances, isEmpty);
    });
  });

  group('StreamingSpeechInput', () {
    late FakeVoiceRecorder recorder;
    late FakeStreamingRecognizer recognizer;
    late DateTime now;

    StreamingSpeechInput input() => StreamingSpeechInput(
      engine: SpeechEngine.vosk,
      modelDirectory: SpeechEngine.voskModelDir,
      store: FakeModelStore({}),
      recorder: recorder,
      recognizer: recognizer,
      clock: () => now,
    );

    setUp(() {
      now = startedAt;
      recorder = FakeVoiceRecorder();
      recognizer = FakeStreamingRecognizer(finalChunk: 2);
    });

    test('results heard while muted are dropped', () async {
      final speech = input();
      await speech.prepare();
      final utterances = <Utterance>[];
      speech.utterances.listen(utterances.add);

      await speech.start();
      speech.muted = true;
      for (var i = 0; i < 2; i++) {
        recorder.audio.add(chunk());
        await pumpEventQueue();
      }
      speech.muted = false;
      await speech.finish();

      expect(utterances, isEmpty);
    });

    test('prepare loads the unpacked model directory', () async {
      await input().prepare();

      expect(recognizer.loadedFrom, 'models/${SpeechEngine.voskModelDir}');
    });

    test('every recognizer result is a separate utterance', () async {
      final speech = input();
      await speech.prepare();
      final partials = <String>[];
      final utterances = <Utterance>[];
      speech.partialText.listen(partials.add);
      speech.utterances.listen(utterances.add);

      await speech.start();
      for (var i = 0; i < 3; i++) {
        recorder.audio.add(chunk());
        await pumpEventQueue();
      }
      now = startedAt.add(const Duration(seconds: 1));
      await speech.finish();

      expect(partials.take(3), ['w1', '', 'w3']);
      expect(utterances.map((u) => u.text), ['w1 w2', 'w3']);
      expect(
        utterances.first.endedAt,
        startedAt.add(const Duration(milliseconds: 200)),
      );
      expect(utterances.last.speechDuration, const Duration(milliseconds: 100));
      expect(recognizer.sessionOpen, isFalse);
    });

    test('every recording opens a new session', () async {
      final speech = input();
      await speech.prepare();

      await speech.start();
      await speech.cancel();
      await speech.start();
      recorder.audio.add(chunk());
      await pumpEventQueue();

      expect(recognizer.sessions, 2);
    });
  });
}
