import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:first_aid_voice_assistant/data/repositories/speech_input.dart';
import 'package:first_aid_voice_assistant/data/repositories/speech_output.dart';
import 'package:first_aid_voice_assistant/data/services/audio_output.dart';
import 'package:first_aid_voice_assistant/data/services/beat_clock.dart';
import 'package:first_aid_voice_assistant/data/services/chat_socket.dart';
import 'package:first_aid_voice_assistant/data/services/emergency_dialer.dart';
import 'package:first_aid_voice_assistant/data/services/metronome_sound.dart';
import 'package:first_aid_voice_assistant/data/services/key_value_store.dart';
import 'package:first_aid_voice_assistant/data/services/model_store.dart';
import 'package:first_aid_voice_assistant/data/services/screen_wake.dart';
import 'package:first_aid_voice_assistant/data/services/segment_decoder.dart';
import 'package:first_aid_voice_assistant/data/services/speech_segmenter.dart';
import 'package:first_aid_voice_assistant/data/services/speech_synthesizer.dart';
import 'package:first_aid_voice_assistant/data/services/streaming_recognizer.dart';
import 'package:first_aid_voice_assistant/data/services/text_to_speech.dart';
import 'package:first_aid_voice_assistant/data/services/voice_recorder.dart';
import 'package:first_aid_voice_assistant/domain/models/speech_engine.dart';
import 'package:first_aid_voice_assistant/domain/models/utterance.dart';

/// Speech input that "recognises" a fixed text when recording ends, for view model and UI tests.
class FakeSpeechInput implements SpeechInput {
  FakeSpeechInput({
    this.text = 'Kolega nie oddycha',
    this.engine = SpeechEngine.parakeet,
  });

  String text;
  final SpeechEngine engine;
  bool permission = true;
  Object? prepareError;
  Object? startError;
  Object? finishError;
  List<double> downloadSteps = [];
  bool listening = false;
  int cancelled = 0;
  @override
  bool muted = false;
  final StreamController<String> _partials =
      StreamController<String>.broadcast();
  final StreamController<Utterance> _utterances =
      StreamController<Utterance>.broadcast();

  void emitPartial(String text) => _partials.add(text);

  void emitUtterance(String text, {DateTime? endedAt}) => _utterances.add(
    Utterance(
      text: text,
      endedAt: endedAt ?? DateTime(2026, 10, 27, 14, 21, 2),
      speechDuration: const Duration(seconds: 2),
      transcriptionDuration: const Duration(milliseconds: 300),
    ),
  );

  @override
  String get label => engine.title;

  @override
  Stream<String> get partialText => _partials.stream;

  @override
  Stream<Utterance> get utterances => _utterances.stream;

  @override
  Future<void> prepare({void Function(double progress)? onProgress}) async {
    downloadSteps.forEach(onProgress ?? (_) {});
    if (prepareError != null) throw prepareError!;
  }

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    listening = true;
  }

  @override
  Future<void> finish() async {
    listening = false;
    if (finishError != null) throw finishError!;
    if (text.isNotEmpty) emitUtterance(text);
    await Future<void>.delayed(Duration.zero);
  }

  @override
  Future<void> cancel() async {
    listening = false;
    cancelled++;
  }

  @override
  Future<void> dispose() async {
    await _partials.close();
    await _utterances.close();
  }
}

class FakeVoiceRecorder implements VoiceRecorder {
  bool permission = true;
  StreamController<Uint8List> audio = StreamController<Uint8List>();
  bool streaming = false;

  @override
  Future<bool> hasPermission() async => permission;

  @override
  Future<Stream<Uint8List>> startStream() async {
    if (audio.isClosed) audio = StreamController<Uint8List>();
    streaming = true;
    return audio.stream;
  }

  @override
  Future<void> stop() async {
    if (!streaming) return;
    streaming = false;
    await audio.close();
  }

  @override
  Future<void> dispose() async {}
}

/// Decoder that answers with the number of samples it was given.
class FakeSegmentDecoder implements SegmentDecoder {
  final List<int> decodedLengths = [];
  String? loadedFrom;

  /// When set, every decode waits for it; lets tests hold a decode in flight.
  Completer<void>? gate;

  @override
  Future<void> load(String modelsDirectory) async =>
      loadedFrom = modelsDirectory;

  @override
  Future<String> decode(Float32List samples) async {
    decodedLengths.add(samples.length);
    await gate?.future;
    return 'n${samples.length}';
  }

  @override
  Future<void> dispose() async {}
}

/// Segmenter that treats audio between the given marks as speech.
class FakeSpeechSegmenter implements SpeechSegmenter {
  FakeSpeechSegmenter({this.speech = const []});

  /// Speech regions, reported once the audio has passed their end.
  final List<SpeechRegion> speech;
  String? loadedFrom;
  int _total = 0;
  int _reported = 0;

  @override
  Future<void> load(String modelPath) async => loadedFrom = modelPath;

  @override
  int? get activeStart {
    for (final region in speech.skip(_reported)) {
      if (region.start <= _total && _total < region.end) return region.start;
    }
    return null;
  }

  @override
  List<SpeechRegion> accept(Float32List samples) {
    _total += samples.length;
    final done = speech
        .skip(_reported)
        .takeWhile((region) => region.end <= _total)
        .toList();
    _reported += done.length;
    return done;
  }

  @override
  List<SpeechRegion> flush() {
    final rest = speech
        .skip(_reported)
        .where((region) => region.start < _total)
        .map((region) => SpeechRegion(region.start, _total))
        .toList();
    _reported = speech.length;
    return rest;
  }

  @override
  void reset() {
    _total = 0;
    _reported = 0;
  }

  @override
  void dispose() {}
}

/// Recognizer that treats every chunk as one word and ends a result on [finalChunk].
class FakeStreamingRecognizer implements StreamingRecognizer {
  FakeStreamingRecognizer({this.finalChunk});

  final int? finalChunk;
  String? loadedFrom;
  int sessions = 0;
  bool sessionOpen = false;
  final List<String> _words = [];
  int _chunks = 0;
  int _resultStart = 0;

  @override
  Future<void> load(String modelDirectory) async => loadedFrom = modelDirectory;

  @override
  Future<void> startSession() async {
    sessions++;
    sessionOpen = true;
    _words.clear();
    _chunks = 0;
    _resultStart = 0;
  }

  @override
  Future<bool> accept(Uint8List pcm16) async {
    _chunks++;
    _words.add('w$_chunks');
    return _chunks == finalChunk;
  }

  @override
  Future<String> partialText() async => _words.join(' ');

  @override
  Future<StreamingResult> result() async => _take();

  @override
  Future<StreamingResult> finalResult() async => _take();

  @override
  Future<void> endSession() async => sessionOpen = false;

  @override
  Future<void> dispose() async {}

  StreamingResult _take() {
    final result = StreamingResult(
      text: _words.join(' '),
      start: Duration(milliseconds: _resultStart * 100),
      end: Duration(milliseconds: _chunks * 100),
    );
    _words.clear();
    _resultStart = _chunks;
    return result;
  }
}

class FakeModelStore implements ModelStore {
  FakeModelStore(this.downloaded);

  final Set<ModelPackage> downloaded;

  @override
  Future<bool> isDownloaded(ModelPackage package) async =>
      downloaded.contains(package);

  @override
  Future<String> ensureDownloaded(
    ModelPackage package, {
    void Function(double progress)? onProgress,
  }) async {
    downloaded.add(package);
    return 'models';
  }
}

/// Speech output that records what it was asked to say; with [holdSentences] every
/// sentence keeps "sounding" until [finishSentence] is called.
class FakeSpeechOutput implements SpeechOutput {
  FakeSpeechOutput({this.label = 'Głos systemowy', this.holdSentences = false});

  @override
  final String label;
  bool holdSentences;
  Object? prepareError;
  Object? speakError;
  List<double> downloadSteps = [];
  final List<String> spoken = [];
  final List<String> prefetched = [];
  int stops = 0;
  bool disposed = false;
  Completer<void>? _sentence;

  bool get isSounding => _sentence != null;

  void finishSentence() {
    final sentence = _sentence;
    _sentence = null;
    sentence?.complete();
  }

  @override
  Future<void> prepare({void Function(double progress)? onProgress}) async {
    downloadSteps.forEach(onProgress ?? (_) {});
    if (prepareError != null) throw prepareError!;
  }

  @override
  void prefetch(String text) => prefetched.add(text);

  @override
  Future<void> speak(String text, {void Function()? onStart}) async {
    if (speakError != null) throw speakError!;
    spoken.add(text);
    onStart?.call();
    if (!holdSentences) return;
    final sentence = Completer<void>();
    _sentence = sentence;
    await sentence.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    finishSentence();
  }

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeChatSocket implements ChatSocket {
  final List<Uri> connectedTo = [];
  Object? connectError;
  FakeChatConnection? connection;

  @override
  Future<ChatConnection> connect(Uri uri, {required Duration timeout}) async {
    if (connectError != null) throw connectError!;
    connectedTo.add(uri);
    return connection = FakeChatConnection();
  }
}

/// Connection that records the messages sent by the app; tests answer with [emit].
class FakeChatConnection implements ChatConnection {
  final StreamController<String> _incoming = StreamController<String>();
  final List<Map<String, dynamic>> sent = [];
  bool closed = false;

  Map<String, dynamic> get lastAsk => sent.lastWhere((m) => m['type'] == 'ask');

  void emit(Map<String, Object?> event) => _incoming.add(jsonEncode(event));

  void step(String? media) =>
      emit({'type': 'step', 'id': lastAsk['id'], 'media': media});

  void delta(String text) =>
      emit({'type': 'delta', 'id': lastAsk['id'], 'text': text});

  void done(String text) => emit({
    'type': 'done',
    'id': lastAsk['id'],
    'text': text,
    'first_token_ms': 120,
    'total_ms': 900,
  });

  Future<void> drop() => _incoming.close();

  @override
  Stream<String> get incoming => _incoming.stream;

  @override
  void send(String message) =>
      sent.add(jsonDecode(message) as Map<String, dynamic>);

  @override
  Future<void> close() async {
    closed = true;
    if (!_incoming.isClosed) await _incoming.close();
  }
}

class FakeMetronomeSound implements MetronomeSound {
  int clicks = 0;
  bool disposed = false;

  @override
  Future<void> click() async => clicks++;

  @override
  Future<void> dispose() async => disposed = true;
}

class FakeEmergencyDialer implements EmergencyDialer {
  bool succeeds = true;
  int calls = 0;

  @override
  Future<bool> dialEmergency() async {
    calls++;
    return succeeds;
  }
}

class FakeTextToSpeech implements TextToSpeech {
  bool languageAvailable = true;
  final List<String> spoken = [];
  int stops = 0;

  @override
  Future<bool> setLanguage(String language) async => languageAvailable;

  @override
  Future<void> speak(String text, {void Function()? onStart}) async {
    spoken.add(text);
    onStart?.call();
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

/// Synthesizer that returns one sample per character, at 22050 Hz.
class FakeSpeechSynthesizer implements SpeechSynthesizer {
  final List<String> synthesized = [];
  String? loadedModel;
  Completer<void>? gate;

  @override
  Future<void> load({
    required String model,
    required String tokens,
    required String espeakVoice,
  }) async => loadedModel = model;

  @override
  Future<SynthesizedSpeech> synthesize(String text) async {
    synthesized.add(text);
    await gate?.future;
    return SynthesizedSpeech(
      samples: Float32List(text.length),
      sampleRate: 22050,
    );
  }

  @override
  Future<void> dispose() async {}
}

class FakeAudioOutput implements AudioOutput {
  final List<Uint8List> played = [];
  int stops = 0;

  @override
  Future<void> playWav(Uint8List wav) async => played.add(wav);

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async {}
}

class MemoryStore implements KeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

/// Beat clock that beats only when a test calls [beat].
class FakeBeatClock implements BeatClock {
  Duration? period;
  void Function()? _onBeat;

  @override
  bool get isRunning => _onBeat != null;

  @override
  void start(Duration period, void Function() onBeat) {
    this.period = period;
    _onBeat = onBeat;
  }

  @override
  void stop() {
    period = null;
    _onBeat = null;
  }

  void beat() => _onBeat?.call();
}

class FakeScreenWake implements ScreenWake {
  bool on = false;

  @override
  Future<void> keepOn() async => on = true;

  @override
  Future<void> release() async => on = false;
}
