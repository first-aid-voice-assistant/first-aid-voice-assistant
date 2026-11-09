import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/speech_engine.dart';
import '../../domain/models/utterance.dart';
import '../../utils/pcm.dart';
import '../../utils/transcript.dart';
import '../services/model_store.dart';
import '../services/segment_decoder.dart';
import '../services/speech_segmenter.dart';
import '../services/streaming_recognizer.dart';
import '../services/voice_recorder.dart';
import 'segmented_transcriber.dart';

abstract interface class SpeechInput {
  String get label;

  Stream<String> get partialText;

  Stream<Utterance> get utterances;

  set muted(bool muted);

  Future<void> prepare({void Function(double progress)? onProgress});

  Future<bool> hasPermission();

  Future<void> start();

  Future<void> finish();

  Future<void> cancel();

  Future<void> dispose();
}

class SpeechInputException implements Exception {
  const SpeechInputException(this.message);

  final String message;

  @override
  String toString() => 'SpeechInputException: $message';
}

const Duration _audioDrainTimeout = Duration(seconds: 2);
const int _sampleRate = 16000;

Duration _samplesToDuration(int samples) => Duration(
  microseconds: samples * Duration.microsecondsPerSecond ~/ _sampleRate,
);

int _durationToBytes(Duration duration) =>
    duration.inMicroseconds * _sampleRate ~/ Duration.microsecondsPerSecond * 2;

Duration _notNegative(Duration duration) =>
    duration.isNegative ? Duration.zero : duration;

class _MutedSpans {
  final List<(int, int)> _spans = [];
  int? _from;

  void set({required bool muted, required int at}) {
    if (muted) {
      _from ??= at;
      return;
    }
    final from = _from;
    if (from == null) return;
    _from = null;
    _spans.add((from, at));
    if (_spans.length > 8) _spans.removeAt(0);
  }

  bool overlaps(int start, int end) {
    final from = _from;
    if (from != null && end > from) return true;
    return _spans.any((span) => end > span.$1 && start < span.$2);
  }

  void clear() {
    _spans.clear();
    _from = null;
  }
}

class SegmentedSpeechInput implements SpeechInput {
  SegmentedSpeechInput({
    required this.engine,
    required this._store,
    required this._recorder,
    required this._segmenter,
    required this._decoder,
    this.partialInterval = const Duration(milliseconds: 500),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final SpeechEngine engine;
  final Duration partialInterval;
  final ModelStore _store;
  final VoiceRecorder _recorder;
  final SpeechSegmenter _segmenter;
  final SegmentDecoder _decoder;
  final DateTime Function() _now;
  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<Utterance> _utterances =
      StreamController<Utterance>.broadcast();
  bool _prepared = false;
  SegmentedTranscriber? _transcriber;
  DateTime? _startedAt;
  final List<StreamSubscription<Object>> _subscriptions = [];
  Completer<void>? _audioDone;
  final _MutedSpans _mutedSpans = _MutedSpans();
  bool _muted = false;
  int _heard = 0;

  @override
  String get label => engine.title;

  @override
  Stream<String> get partialText => _partials.stream;

  @override
  Stream<Utterance> get utterances => _utterances.stream;

  @override
  set muted(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    _mutedSpans.set(muted: muted, at: _heard);
    if (muted && !_partials.isClosed) _partials.add('');
  }

  @override
  Future<void> prepare({void Function(double progress)? onProgress}) async {
    final directory = await _store.ensureDownloaded(
      engine,
      onProgress: onProgress,
    );
    await _segmenter.load('$directory/${SpeechEngine.vadModelPath}');
    await _decoder.load(directory);
    await _decoder.decode(Float32List(_sampleRate));
    _prepared = true;
  }

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    if (!_prepared) throw const SpeechInputException('Model is not prepared');
    _segmenter.reset();
    _heard = 0;
    _mutedSpans.clear();
    _mutedSpans.set(muted: _muted, at: 0);
    final pcm = Pcm16Decoder();
    final transcriber = SegmentedTranscriber(
      decode: _decoder.decode,
      partialInterval: partialInterval,
      clock: _now,
    );
    _transcriber = transcriber;
    _subscriptions
      ..add(
        transcriber.partialText.listen(
          (text) => _partials.add(_muted ? '' : cleanTranscript(text)),
        ),
      )
      ..add(transcriber.segments.listen(_onSegment));
    final audioDone = Completer<void>();
    _audioDone = audioDone;

    void endOfAudio() {
      if (!audioDone.isCompleted) audioDone.complete();
    }

    try {
      final audio = await _recorder.startStream();
      _startedAt = _now();
      _subscriptions.add(
        audio.listen(
          (chunk) {
            final samples = pcm.convert(chunk);
            if (_muted) samples.fillRange(0, samples.length, 0);
            _heard += samples.length;
            transcriber.addAudio(samples);
            _segmenter.accept(samples).forEach(transcriber.addRegion);
            transcriber.setActiveStart(_segmenter.activeStart);
          },
          onDone: endOfAudio,
          onError: (Object _) => endOfAudio(),
        ),
      );
    } catch (_) {
      await transcriber.cancel();
      await _reset();
      rethrow;
    }
  }

  @override
  Future<void> finish() async {
    final transcriber = _transcriber;
    if (transcriber == null) {
      throw const SpeechInputException('Recognition was not started');
    }
    await _recorder.stop();
    await _audioDone?.future.timeout(_audioDrainTimeout, onTimeout: () {});
    _segmenter.flush().forEach(transcriber.addRegion);
    try {
      await transcriber.finish();
    } finally {
      await _reset();
    }
  }

  @override
  Future<void> cancel() async {
    await _recorder.stop();
    final transcriber = _transcriber;
    await transcriber?.cancel();
    await _reset();
  }

  void _onSegment(TranscribedSegment segment) {
    final startedAt = _startedAt;
    final text = cleanTranscript(segment.text);
    if (startedAt == null || text.isEmpty || _utterances.isClosed) return;
    if (_mutedSpans.overlaps(segment.region.start, segment.region.end)) return;
    final endedAt = startedAt.add(_samplesToDuration(segment.region.end));
    _utterances.add(
      Utterance(
        text: text,
        endedAt: endedAt,
        speechDuration: _samplesToDuration(segment.region.length),
        transcriptionDuration: _notNegative(
          segment.decodedAt.difference(endedAt),
        ),
      ),
    );
  }

  Future<void> _reset() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    _transcriber = null;
    _audioDone = null;
    _startedAt = null;
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
    await _decoder.dispose();
    _segmenter.dispose();
    await _partials.close();
    await _utterances.close();
  }
}

class StreamingSpeechInput implements SpeechInput {
  StreamingSpeechInput({
    required this.engine,
    required this.modelDirectory,
    required this._store,
    required this._recorder,
    required this._recognizer,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final SpeechEngine engine;
  final String modelDirectory;
  final ModelStore _store;
  final VoiceRecorder _recorder;
  final StreamingRecognizer _recognizer;
  final DateTime Function() _now;
  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<Utterance> _utterances =
      StreamController<Utterance>.broadcast();
  bool _prepared = false;
  bool _active = false;
  Future<void> _queue = Future<void>.value();
  Object? _lastError;
  int _produced = 0;
  int _receivedBytes = 0;
  int _resultStartBytes = 0;
  DateTime? _startedAt;
  StreamSubscription<Uint8List>? _audio;
  Completer<void>? _audioDone;
  final _MutedSpans _mutedSpans = _MutedSpans();
  bool _muted = false;
  int _heardBytes = 0;

  @override
  String get label => engine.title;

  @override
  Stream<String> get partialText => _partials.stream;

  @override
  Stream<Utterance> get utterances => _utterances.stream;

  @override
  set muted(bool muted) {
    if (muted == _muted) return;
    _muted = muted;
    _mutedSpans.set(muted: muted, at: _heardBytes);
    if (muted) _emitPartial('');
  }

  @override
  Future<void> prepare({void Function(double progress)? onProgress}) async {
    final directory = await _store.ensureDownloaded(
      engine,
      onProgress: onProgress,
    );
    await _recognizer.load('$directory/$modelDirectory');
    _prepared = true;
  }

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start() async {
    if (!_prepared) throw const SpeechInputException('Model is not prepared');
    _lastError = null;
    _produced = 0;
    _receivedBytes = 0;
    _resultStartBytes = 0;
    _heardBytes = 0;
    _mutedSpans.clear();
    _mutedSpans.set(muted: _muted, at: 0);
    _queue = Future<void>.value();
    await _recognizer.startSession();
    _active = true;
    final audioDone = Completer<void>();
    _audioDone = audioDone;

    void endOfAudio() {
      if (!audioDone.isCompleted) audioDone.complete();
    }

    try {
      final audio = await _recorder.startStream();
      _startedAt = _now();
      _audio = audio.listen(
        (chunk) {
          final heard = _muted ? Uint8List(chunk.length) : chunk;
          _heardBytes += heard.length;
          _enqueue(() => _accept(heard));
        },
        onDone: endOfAudio,
        onError: (Object _) => endOfAudio(),
      );
    } catch (_) {
      await _endSession();
      rethrow;
    }
  }

  @override
  Future<void> finish() async {
    if (!_active) {
      throw const SpeechInputException('Recognition was not started');
    }
    await _recorder.stop();
    await _audioDone?.future.timeout(_audioDrainTimeout, onTimeout: () {});
    try {
      await _queue;
      _addUtterance(await _recognizer.finalResult());
      _partials.add('');
      final error = _lastError;
      if (_produced == 0 && error != null) throw error;
    } finally {
      await _endSession();
    }
  }

  @override
  Future<void> cancel() async {
    await _recorder.stop();
    if (!_active) return;
    await _audio?.cancel();
    _audio = null;
    await _queue;
    await _endSession();
  }

  void _enqueue(Future<void> Function() job) {
    _queue = _queue.then((_) => job()).catchError((Object error) {
      debugPrint('Streaming recognition failed: $error');
      _lastError = error;
    });
  }

  Future<void> _accept(Uint8List chunk) async {
    if (!_active) return;
    _receivedBytes += chunk.length;
    if (await _recognizer.accept(chunk)) {
      _addUtterance(await _recognizer.result());
      _emitPartial('');
    } else {
      _emitPartial(await _recognizer.partialText());
    }
  }

  void _addUtterance(StreamingResult result) {
    final startedAt = _startedAt;
    final text = cleanTranscript(result.text);
    final resultStart = _samplesToDuration(_resultStartBytes ~/ 2);
    final received = _samplesToDuration(_receivedBytes ~/ 2);
    _resultStartBytes = _receivedBytes;
    if (startedAt == null || text.isEmpty || _utterances.isClosed) return;
    final speechStart = result.start ?? resultStart;
    final speechEnd = result.end ?? received;
    if (_mutedSpans.overlaps(
      _durationToBytes(speechStart),
      _durationToBytes(speechEnd),
    )) {
      return;
    }
    final endedAt = startedAt.add(speechEnd);
    _produced++;
    _utterances.add(
      Utterance(
        text: text,
        endedAt: endedAt,
        speechDuration: _notNegative(speechEnd - speechStart),
        transcriptionDuration: _notNegative(_now().difference(endedAt)),
      ),
    );
  }

  void _emitPartial(String partial) {
    if (_partials.isClosed) return;
    _partials.add(_muted ? '' : cleanTranscript(partial));
  }

  Future<void> _endSession() async {
    _active = false;
    await _audio?.cancel();
    _audio = null;
    _audioDone = null;
    await _recognizer.endSession();
  }

  @override
  Future<void> dispose() async {
    await cancel();
    await _recorder.dispose();
    await _recognizer.dispose();
    await _partials.close();
    await _utterances.close();
  }
}
