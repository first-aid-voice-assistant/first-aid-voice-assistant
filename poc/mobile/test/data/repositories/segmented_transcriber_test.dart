import 'dart:async';
import 'dart:typed_data';

import 'package:first_aid_voice_assistant/data/repositories/segmented_transcriber.dart';
import 'package:first_aid_voice_assistant/data/services/speech_segmenter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/services.dart';

void main() {
  late FakeSegmentDecoder decoder;
  late DateTime now;

  SegmentedTranscriber transcriber() => SegmentedTranscriber(
    decode: decoder.decode,
    minDecodeSamples: 100,
    clock: () => now,
  );

  setUp(() {
    decoder = FakeSegmentDecoder();
    now = DateTime(2026);
  });

  test('does not decode audio outside speech', () async {
    final t = transcriber();

    t.addAudio(Float32List(5000));
    await pumpEventQueue();
    await t.finish();

    expect(decoder.decodedLengths, isEmpty);
  });

  test('shows a partial result of the speech in progress only', () async {
    final t = transcriber();
    final partials = <String>[];
    t.partialText.listen(partials.add);

    t.addAudio(Float32List(1000));
    t.setActiveStart(600);
    await pumpEventQueue();

    expect(partials, ['n400']);
  });

  test('decodes at most once per interval and never in parallel', () async {
    final t = transcriber();
    decoder.gate = Completer<void>();
    t.setActiveStart(0);

    t.addAudio(Float32List(500));
    t.addAudio(Float32List(500));
    now = now.add(const Duration(seconds: 1));
    t.addAudio(Float32List(500));
    await pumpEventQueue();

    expect(decoder.decodedLengths, [500]);
    decoder.gate!.complete();
    await pumpEventQueue();
    expect(decoder.decodedLengths, [500, 1500]);
  });

  test('every speech region becomes its own segment', () async {
    final t = transcriber();
    final segments = <TranscribedSegment>[];
    t.segments.listen(segments.add);

    t.addAudio(Float32List(3000));
    t.addRegion(const SpeechRegion(200, 1000));
    t.addRegion(const SpeechRegion(1500, 2700));
    await t.finish();

    expect(segments.map((s) => s.text), ['n800', 'n1200']);
    expect(segments.last.region.end, 2700);
    expect(segments.last.decodedAt, now);
  });

  test('clears the partial text once the region is committed', () async {
    final t = transcriber();
    final partials = <String>[];
    t.partialText.listen(partials.add);

    t.addAudio(Float32List(1000));
    t.setActiveStart(0);
    await pumpEventQueue();
    t.setActiveStart(null);
    t.addRegion(const SpeechRegion(0, 1000));
    await t.finish();

    expect(partials, ['n1000', '']);
  });

  test('skips regions that are too short to decode', () async {
    final t = transcriber();
    final segments = <TranscribedSegment>[];
    t.segments.listen(segments.add);

    t.addAudio(Float32List(1000));
    t.addRegion(const SpeechRegion(0, 50));
    await t.finish();

    expect(segments, isEmpty);
    expect(decoder.decodedLengths, isEmpty);
  });

  test('cancel waits for the decode in flight and discards it', () async {
    final t = transcriber();
    final segments = <TranscribedSegment>[];
    t.segments.listen(segments.add);
    decoder.gate = Completer<void>();
    t.addAudio(Float32List(500));
    t.addRegion(const SpeechRegion(0, 500));
    await pumpEventQueue();

    final cancelled = t.cancel();
    decoder.gate!.complete();
    await cancelled;

    expect(segments, isEmpty);
  });

  test('long listening keeps only the recent audio', () async {
    final t = SegmentedTranscriber(
      decode: decoder.decode,
      minDecodeSamples: 100,
      keptSamples: 1000,
      clock: () => now,
    );

    for (var i = 0; i < 10; i++) {
      t.addAudio(Float32List(500));
    }

    expect(t.length, 5000);
    expect(t.keptFrom, greaterThanOrEqualTo(3000));
  });

  test('old audio of speech still waiting to be decoded is kept', () async {
    final t = SegmentedTranscriber(
      decode: decoder.decode,
      minDecodeSamples: 100,
      keptSamples: 1000,
      clock: () => now,
    );
    decoder.gate = Completer<void>();
    t.addAudio(Float32List(500));
    t.addRegion(const SpeechRegion(0, 300));
    t.addRegion(const SpeechRegion(200, 500));

    for (var i = 0; i < 10; i++) {
      t.addAudio(Float32List(500));
    }
    expect(t.keptFrom, lessThanOrEqualTo(200));

    decoder.gate!.complete();
    await t.finish();
    expect(decoder.decodedLengths, [300, 300]);
  });
}
