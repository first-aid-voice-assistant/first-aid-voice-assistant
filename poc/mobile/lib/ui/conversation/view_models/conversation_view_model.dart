import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/answer_speaker.dart';
import '../../../data/repositories/assistant_repository.dart';
import '../../../data/repositories/speech_input.dart';
import '../../../data/repositories/speech_output.dart';
import '../../../data/services/metronome_sound.dart';
import '../../../domain/models/chat_message.dart';
import '../../../domain/models/conversation_entry.dart';
import '../../../domain/models/illustration.dart';
import '../../../domain/models/utterance.dart';

enum ConversationStatus {
  preparingModel,
  ready,
  starting,
  recording,
  transcribing,
  failed,
}

enum AssistantActivity { idle, thinking, speaking }

const Duration endOfTurnSilence = Duration(milliseconds: 1200);

const String noServerAnswer =
    'Nie mam połączenia z serwerem asystenta. '
    'Jeśli to nagły wypadek, zadzwoń pod numer sto dwanaście.';

class ConversationViewModel extends ChangeNotifier {
  ConversationViewModel({
    required this._input,
    required this._output,
    required this._assistant,
    this._metronome,
    this.endOfTurn = endOfTurnSilence,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final SpeechInput _input;
  final SpeechOutput _output;
  final AssistantRepository _assistant;
  final MetronomeSound? _metronome;
  final Duration endOfTurn;
  final DateTime Function() _now;

  final List<ConversationEntry> _entries = [];
  ConversationStatus _status = ConversationStatus.preparingModel;
  String? _message;
  String _partialText = '';
  String _preparingLabel = '';
  double? _downloadProgress;
  Utterance? _lastInTurn;
  Timer? _turnTimer;
  StreamSubscription<String>? _partials;
  StreamSubscription<Utterance>? _recognized;
  StreamSubscription<AnswerEvent>? _answer;
  AnswerSpeaker? _speaker;
  int? _answerIndex;
  String? _media;
  DateTime? _mediaSince;
  bool _disposed = false;

  List<ConversationEntry> get entries => List.unmodifiable(_entries);
  List<Utterance> get utterances => [
    for (final entry in _entries)
      if (entry is UserMessage) entry.utterance,
  ];
  List<AssistantMessage> get answers =>
      _entries.whereType<AssistantMessage>().toList(growable: false);
  ConversationStatus get status => _status;
  String get modelLabel => _input.label;
  String get voiceLabel => _output.label;
  String get preparingLabel => _preparingLabel;
  String? get message => _message;
  String get partialText => _partialText;
  double? get downloadProgress => _downloadProgress;
  bool get canRecord =>
      _status == ConversationStatus.ready &&
      assistantActivity == AssistantActivity.idle;
  bool get isRecording => _status == ConversationStatus.recording;
  String? get media => _media;
  Duration get mediaShownFor =>
      _mediaSince == null ? Duration.zero : _now().difference(_mediaSince!);

  bool get metronomeAudible =>
      Illustrations.of(_media).hasMetronome &&
      _status == ConversationStatus.ready &&
      assistantActivity == AssistantActivity.idle;

  void onMetronomeBeat() {
    final metronome = _metronome;
    if (_disposed || metronome == null || !metronomeAudible) return;
    unawaited(metronome.click());
  }

  String? get latestAnswer {
    final answer = _entries.whereType<AssistantMessage>().lastOrNull;
    return answer == null || answer.text.isEmpty ? null : answer.text;
  }

  String? get latestUserText {
    if (_partialText.isNotEmpty &&
        (_status == ConversationStatus.recording ||
            _status == ConversationStatus.transcribing)) {
      return _partialText;
    }
    for (final entry in _entries.reversed) {
      if (entry is UserMessage) return entry.utterance.text;
    }
    return null;
  }

  AssistantActivity get assistantActivity {
    final speaker = _speaker;
    if (speaker == null) return AssistantActivity.idle;
    if (speaker.isSpeaking) return AssistantActivity.speaking;
    if (speaker.isActive || (_currentAnswer?.inProgress ?? false)) {
      return AssistantActivity.thinking;
    }
    return AssistantActivity.idle;
  }

  AssistantMessage? get _currentAnswer {
    final index = _answerIndex;
    return index == null ? null : _entries[index] as AssistantMessage;
  }

  Future<void> initialize() async {
    _partials ??= _input.partialText.listen(_onPartialText);
    _recognized ??= _input.utterances.listen(_onUtterance);
    _downloadProgress = null;
    _preparingLabel = _input.label;
    _setStatus(ConversationStatus.preparingModel);
    try {
      await _input.prepare(onProgress: _onDownloadProgress);
    } catch (e) {
      debugPrint('Preparing speech recognition failed: $e');
      _setStatus(
        ConversationStatus.failed,
        message:
            'Nie udało się przygotować modelu rozpoznawania mowy. '
            'Sprawdź połączenie z internetem i spróbuj ponownie.',
      );
      return;
    }
    _downloadProgress = null;
    _preparingLabel = _output.label;
    notifyListeners();
    try {
      await _output.prepare(onProgress: _onDownloadProgress);
    } catch (e) {
      debugPrint('Preparing the voice failed: $e');
      _setStatus(
        ConversationStatus.failed,
        message: e is MissingVoiceException
            ? 'Telefon nie ma polskiego głosu systemowego. Zainstaluj go '
                  'w ustawieniach mowy telefonu albo wybierz głos Piper.'
            : 'Nie udało się przygotować głosu asystenta. '
                  'Sprawdź połączenie z internetem i spróbuj ponownie.',
      );
      return;
    }
    _downloadProgress = null;
    _setStatus(ConversationStatus.ready);
  }

  Future<void> toggleRecording() async {
    if (isRecording) {
      await stopRecording();
    } else {
      await startRecording();
    }
  }

  Future<void> startRecording() async {
    if (!canRecord) return;
    _setStatus(ConversationStatus.starting);
    if (!await _input.hasPermission()) {
      _setStatus(
        ConversationStatus.ready,
        message: 'Brak dostępu do mikrofonu. Zezwól na niego w ustawieniach telefonu.',
      );
      return;
    }
    try {
      await _input.start();
    } catch (e) {
      debugPrint('Starting speech recognition failed: $e');
      _setStatus(
        ConversationStatus.ready,
        message: 'Nie udało się uruchomić nagrywania.',
      );
      return;
    }
    _partialText = '';
    _lastInTurn = null;
    _setStatus(ConversationStatus.recording);
  }

  Future<void> stopRecording() async {
    if (!isRecording) return;
    _turnTimer?.cancel();
    _setStatus(ConversationStatus.transcribing);
    String? failure;
    try {
      await _input.finish();
    } catch (e) {
      debugPrint('Speech recognition failed: $e');
      failure = 'Nie udało się rozpoznać mowy.';
    }
    _partialText = '';
    final last = _lastInTurn;
    _lastInTurn = null;
    if (last == null) {
      _setStatus(
        ConversationStatus.ready,
        message: failure ?? 'Nie rozpoznano mowy. Spróbuj jeszcze raz.',
      );
      return;
    }
    _setStatus(ConversationStatus.ready);
    _ask(last);
    notifyListeners();
  }

  Future<void> stopAnswer() async {
    if (assistantActivity == AssistantActivity.idle) return;
    _interruptAnswer();
    await _assistant.cancel();
    _notify();
  }

  void _onUtterance(Utterance utterance) {
    if (_disposed) return;
    _entries.add(UserMessage(utterance));
    _lastInTurn = utterance;
    _partialText = '';
    if (isRecording) {
      _turnTimer?.cancel();
      _turnTimer = Timer(endOfTurn, stopRecording);
    }
    notifyListeners();
  }

  void _ask(Utterance utterance) {
    final history = _history();
    final question = history.removeLast();
    _entries.add(const AssistantMessage());
    _answerIndex = _entries.length - 1;
    late final AnswerSpeaker speaker;
    speaker = AnswerSpeaker(
      _output,
      clock: _now,
      onFirstSound: () => _updateAnswer(
        speaker,
        (answer) => answer.copyWith(
          firstSoundAfter: _now().difference(utterance.endedAt),
        ),
      ),
      onChange: _notify,
      onError: (_) =>
          _notify(message: 'Nie udało się odczytać odpowiedzi na głos.'),
    );
    _speaker = speaker;
    _answer = _assistant
        .ask(text: question.content, history: history)
        .listen((event) => _onAnswerEvent(event, speaker));
  }

  List<ChatMessage> _history() {
    final messages = <ChatMessage>[];
    for (final entry in _entries) {
      final message = switch (entry) {
        UserMessage(:final utterance) => ChatMessage.user(utterance.text),
        AssistantMessage() => switch (entry.heardByUser) {
          final heard? => ChatMessage.assistant(heard),
          null => null,
        },
      };
      if (message == null) continue;
      if (messages.isNotEmpty && messages.last.role == message.role) {
        final previous = messages.removeLast();
        messages.add(
          ChatMessage(
            role: message.role,
            content: '${previous.content} ${message.content}',
          ),
        );
      } else {
        messages.add(message);
      }
    }
    return messages;
  }

  void _onAnswerEvent(AnswerEvent event, AnswerSpeaker speaker) {
    if (_disposed || !identical(_speaker, speaker)) return;
    switch (event) {
      case AnswerStep(:final media):
        if (media != _media) {
          _media = media;
          _mediaSince = _now();
          notifyListeners();
        }
      case AnswerDelta(:final text):
        _updateAnswer(
          speaker,
          (answer) => answer.copyWith(
            text: answer.text + text,
            state: AnswerState.streaming,
          ),
        );
        speaker.add(text);
      case AnswerCompleted(:final text, :final firstTokenTime):
        final received = _currentAnswer?.text ?? '';
        if (text.startsWith(received)) {
          speaker.add(text.substring(received.length));
        }
        _updateAnswer(
          speaker,
          (answer) => answer.copyWith(
            text: text,
            state: AnswerState.completed,
            firstTokenTime: firstTokenTime,
          ),
        );
        speaker.finish();
      case AnswerFailed():
        _updateAnswer(
          speaker,
          (answer) =>
              answer.copyWith(text: noServerAnswer, state: AnswerState.failed),
        );
        unawaited(speaker.stop());
        final fallback = AnswerSpeaker(_output, clock: _now, onChange: _notify);
        _speaker = fallback;
        fallback.say(noServerAnswer);
        _notify(
          message: 'Brak odpowiedzi serwera. W nagłym wypadku dzwoń pod 112.',
        );
    }
  }

  void _updateAnswer(
    AnswerSpeaker speaker,
    AssistantMessage Function(AssistantMessage answer) update,
  ) {
    final index = _answerIndex;
    if (_disposed || index == null || !identical(_speaker, speaker)) return;
    _entries[index] = update(_entries[index] as AssistantMessage);
    notifyListeners();
  }

  void _interruptAnswer() {
    final speaker = _speaker;
    final index = _answerIndex;
    unawaited(_answer?.cancel());
    _answer = null;
    _speaker = null;
    _answerIndex = null;
    if (speaker == null || index == null) return;
    final answer = _entries[index] as AssistantMessage;
    final stillSpeaking = speaker.isActive;
    unawaited(speaker.stop());
    if (answer.state == AnswerState.waiting && answer.text.isEmpty) {
      _entries.removeAt(index);
    } else if (answer.inProgress ||
        (answer.state == AnswerState.completed && stillSpeaking)) {
      _entries[index] = answer.copyWith(
        state: AnswerState.interrupted,
        spokenText: speaker.spokenText,
      );
    }
  }

  void _onPartialText(String text) {
    if (_disposed) return;
    if (_status != ConversationStatus.recording &&
        _status != ConversationStatus.transcribing) {
      return;
    }
    _partialText = text;
    if (text.isNotEmpty) _turnTimer?.cancel();
    notifyListeners();
  }

  void _onDownloadProgress(double progress) {
    final previous = ((_downloadProgress ?? -1) * 100).floor();
    _downloadProgress = progress;
    if (!_disposed && (progress * 100).floor() != previous) notifyListeners();
  }

  void _notify({String? message}) {
    if (_disposed) return;
    if (message != null) _message = message;
    notifyListeners();
  }

  void _setStatus(ConversationStatus status, {String? message}) {
    if (_disposed) return;
    _status = status;
    _message = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _turnTimer?.cancel();
    _partials?.cancel();
    _recognized?.cancel();
    _answer?.cancel();
    _speaker?.stop();
    _input.dispose();
    _output.dispose();
    _assistant.dispose();
    _metronome?.dispose();
    super.dispose();
  }
}
