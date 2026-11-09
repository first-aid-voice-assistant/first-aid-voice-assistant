import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../data/repositories/answer_speaker.dart';
import '../../../data/repositories/assistant_repository.dart';
import '../../../data/repositories/speech_input.dart';
import '../../../data/repositories/speech_output.dart';
import '../../../data/services/beat_clock.dart';
import '../../../data/services/metronome_sound.dart';
import '../../../data/services/screen_wake.dart';
import '../../../domain/models/chat_message.dart';
import '../../../domain/models/conversation_entry.dart';
import '../../../domain/models/illustration.dart';
import '../../../domain/models/utterance.dart';
import '../../../utils/counting.dart';

enum ConversationStatus { preparingModel, starting, listening, paused, failed }

enum PauseReason { assistantSpeaking, microphoneUnavailable }

enum AssistantActivity { idle, thinking, speaking }

const Duration endOfTurnSilence = Duration(milliseconds: 1200);

const Duration listenAgainAfter = Duration(milliseconds: 300);

const String greeting = 'Powiedz, co się stało. Słucham cały czas.';

const Duration compressionReminderAfter = Duration(seconds: 60);

const String compressionReminder = 'Uciskaj dalej w rytm sygnału.';

const String noServerAnswer =
    'Nie mam połączenia z serwerem asystenta. '
    'Jeśli to nagły wypadek, zadzwoń pod numer sto dwanaście.';

class ConversationViewModel extends ChangeNotifier {
  ConversationViewModel({
    required this._input,
    required this._output,
    required this._assistant,
    this._metronome,
    BeatClock? beatClock,
    this._screenWake,
    this.endOfTurn = endOfTurnSilence,
    this.listenAgain = listenAgainAfter,
    this.reminderAfter = compressionReminderAfter,
    DateTime Function()? clock,
  }) : _beatClock = beatClock ?? TimerBeatClock(),
       _now = clock ?? DateTime.now;

  final SpeechInput _input;
  final SpeechOutput _output;
  final AssistantRepository _assistant;
  final MetronomeSound? _metronome;
  final BeatClock _beatClock;
  final ScreenWake? _screenWake;
  final Duration endOfTurn;
  final Duration listenAgain;
  final Duration reminderAfter;
  final DateTime Function() _now;

  final List<ConversationEntry> _entries = [];
  final StreamController<void> _beats = StreamController<void>.broadcast();
  ConversationStatus _status = ConversationStatus.preparingModel;
  PauseReason? _pauseReason;
  bool _greeted = false;
  bool _recording = false;
  String? _message;
  String _partialText = '';
  String _preparingLabel = '';
  double? _downloadProgress;
  Utterance? _waiting;
  Timer? _turnTimer;
  Timer? _listenTimer;
  StreamSubscription<String>? _partials;
  StreamSubscription<Utterance>? _recognized;
  StreamSubscription<AnswerEvent>? _answer;
  AnswerSpeaker? _speaker;
  int? _answerIndex;
  String? _media;
  DateTime? _mediaSince;
  DateTime? _lastActivityAt;
  bool _disposed = false;

  List<ConversationEntry> get entries => List.unmodifiable(_entries);
  List<Utterance> get utterances => [
    for (final entry in _entries)
      if (entry is UserMessage) entry.utterance,
  ];
  List<AssistantMessage> get answers =>
      _entries.whereType<AssistantMessage>().toList(growable: false);
  ConversationStatus get status => _status;
  PauseReason? get pauseReason =>
      _status == ConversationStatus.paused ? _pauseReason : null;
  bool get isListening => _status == ConversationStatus.listening;
  bool get canResume =>
      _status == ConversationStatus.paused &&
      _pauseReason != PauseReason.assistantSpeaking;
  String get modelLabel => _input.label;
  String get voiceLabel => _output.label;
  String get preparingLabel => _preparingLabel;
  String? get message => _message;
  String get partialText => _partialText;
  double? get downloadProgress => _downloadProgress;
  String? get media => _media;
  Duration get mediaShownFor =>
      _mediaSince == null ? Duration.zero : _now().difference(_mediaSince!);
  Stream<void> get beats => _beats.stream;

  bool get metronomeAudible => Illustrations.of(_media).hasMetronome;

  String? get latestAnswer {
    final answer = _entries.whereType<AssistantMessage>().lastOrNull;
    return answer == null || answer.text.isEmpty ? null : answer.text;
  }

  String? get latestUserText {
    if (_partialText.isNotEmpty) return _partialText;
    for (final entry in _entries.reversed) {
      if (entry is UserMessage) return entry.utterance.text;
    }
    return null;
  }

  AssistantActivity get assistantActivity {
    final speaker = _speaker;
    if (speaker == null) return AssistantActivity.idle;
    if (speaker.isSpeaking) return AssistantActivity.speaking;
    if (_answerInProgress) return AssistantActivity.thinking;
    return AssistantActivity.idle;
  }

  bool get _answerInProgress =>
      (_speaker?.isActive ?? false) || (_currentAnswer?.inProgress ?? false);

  bool get _assistantAudible {
    final speaker = _speaker;
    return speaker != null && speaker.isActive && speaker.firstSoundAt != null;
  }

  bool get _assistantAboutToSpeak {
    final speaker = _speaker;
    if (speaker == null || !speaker.isActive) return false;
    return speaker.firstSoundAt != null ||
        !(_currentAnswer?.inProgress ?? false);
  }

  AssistantMessage? get _currentAnswer {
    final index = _answerIndex;
    return index == null ? null : _entries[index] as AssistantMessage;
  }

  Future<void> initialize() async {
    _partials ??= _input.partialText.listen(_onPartialText);
    _recognized ??= _input.utterances.listen(_onUtterance);
    unawaited(_screenWake?.keepOn());
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
    _notify();
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
    if (!_greeted) {
      _greeted = true;
      _say(greeting);
    }
    await _startListening();
  }

  Future<void> resume() async {
    if (canResume) await _startListening();
  }

  Future<void> stopAnswer() async {
    if (assistantActivity == AssistantActivity.idle) return;
    _interruptAnswer();
    await _assistant.cancel();
    _lastActivityAt = _now();
    _askWaiting();
    _listenAgainSoon();
    _notify();
  }

  Future<void> _startListening() async {
    if (_disposed) return;
    if (_assistantAboutToSpeak) {
      _pause(PauseReason.assistantSpeaking);
      return;
    }
    final message = _pauseReason == PauseReason.microphoneUnavailable
        ? null
        : _message;
    _input.muted = false;
    if (_recording) {
      _partialText = '';
      _setStatus(ConversationStatus.listening, message: message);
      return;
    }
    _setStatus(ConversationStatus.starting, message: message);
    if (!await _input.hasPermission()) {
      _pause(
        PauseReason.microphoneUnavailable,
        message:
            'Brak dostępu do mikrofonu. Zezwól na niego w ustawieniach '
            'telefonu i naciśnij mikrofon.',
      );
      return;
    }
    try {
      await _input.start();
    } catch (e) {
      debugPrint('Starting speech recognition failed: $e');
      _pause(
        PauseReason.microphoneUnavailable,
        message: 'Nie udało się włączyć mikrofonu. Naciśnij go, aby ponowić.',
      );
      return;
    }
    _recording = true;
    if (_disposed || _status != ConversationStatus.starting) return;
    _partialText = '';
    _setStatus(ConversationStatus.listening, message: message);
  }

  void _pause(PauseReason reason, {String? message}) {
    _pauseReason = reason;
    _setStatus(ConversationStatus.paused, message: message ?? _message);
  }

  void _onAssistantSound(AnswerSpeaker speaker) {
    if (_disposed || !identical(_speaker, speaker)) return;
    _listenTimer?.cancel();
    if (_status == ConversationStatus.listening ||
        _status == ConversationStatus.starting) {
      _input.muted = true;
      _partialText = '';
      _pause(PauseReason.assistantSpeaking);
    }
  }

  void _listenAgainSoon() {
    _listenTimer?.cancel();
    if (_status != ConversationStatus.paused ||
        _pauseReason != PauseReason.assistantSpeaking) {
      return;
    }
    _listenTimer = Timer(listenAgain, () {
      if (_disposed ||
          _status != ConversationStatus.paused ||
          _pauseReason != PauseReason.assistantSpeaking) {
        return;
      }
      unawaited(_startListening());
    });
  }

  void _onUtterance(Utterance utterance) {
    if (_disposed) return;
    if (isCountingOrFiller(utterance.text)) {
      debugPrint('Ignored counting or a filler');
      if (_turnTimer == null) _scheduleTurnEnd();
      return;
    }
    _entries.add(UserMessage(utterance));
    _partialText = '';
    _lastActivityAt = _now();
    _waiting = utterance;
    if (_answerInProgress && !_assistantAudible) {
      _interruptAnswer();
      unawaited(_assistant.cancel());
    }
    _scheduleTurnEnd();
    notifyListeners();
  }

  void _onPartialText(String text) {
    if (_disposed) return;
    final userSpeech = text.isNotEmpty && !isCountingOrFiller(text);
    _partialText = userSpeech ? text : '';
    if (userSpeech) {
      _cancelTurnTimer();
      _lastActivityAt = _now();
    } else if (_turnTimer == null) {
      _scheduleTurnEnd();
    }
    notifyListeners();
  }

  void _scheduleTurnEnd() {
    _cancelTurnTimer();
    if (_disposed || _waiting == null || _assistantAudible) return;
    _turnTimer = Timer(endOfTurn, _endTurn);
  }

  void _cancelTurnTimer() {
    _turnTimer?.cancel();
    _turnTimer = null;
  }

  void _endTurn() {
    _turnTimer = null;
    if (_disposed || _assistantAudible || _partialText.isNotEmpty) return;
    _askWaiting();
  }

  void _onAnswerSpoken(AnswerSpeaker speaker) {
    if (_disposed || !identical(_speaker, speaker)) return;
    _lastActivityAt = _now();
    _askWaiting();
    _listenAgainSoon();
    _notify();
  }

  void _askWaiting() {
    final waiting = _waiting;
    if (waiting == null || _disposed) return;
    _waiting = null;
    _cancelTurnTimer();
    _speaker = null;
    _answerIndex = null;
    _ask(waiting);
  }

  AnswerSpeaker _newSpeaker({void Function()? onFirstSound}) {
    late final AnswerSpeaker speaker;
    speaker = AnswerSpeaker(
      _output,
      clock: _now,
      onFirstSound: () {
        _onAssistantSound(speaker);
        onFirstSound?.call();
      },
      onChange: _notify,
      onError: (_) =>
          _notify(message: 'Nie udało się odczytać odpowiedzi na głos.'),
    );
    _speaker = speaker;
    speaker.done.then((_) => _onAnswerSpoken(speaker));
    return speaker;
  }

  void _say(String text, {bool reminder = false}) {
    _lastActivityAt = _now();
    _entries.add(
      AssistantMessage(
        text: text,
        state: AnswerState.completed,
        reminder: reminder,
      ),
    );
    _answerIndex = _entries.length - 1;
    _newSpeaker().say(text);
    notifyListeners();
  }

  void _ask(Utterance utterance) {
    final history = _history();
    if (history.isEmpty || history.last.role != ChatRole.user) return;
    final question = history.removeLast();
    _message = null;
    _lastActivityAt = _now();
    _entries.add(const AssistantMessage());
    _answerIndex = _entries.length - 1;
    late final AnswerSpeaker speaker;
    speaker = _newSpeaker(
      onFirstSound: () => _updateAnswer(
        speaker,
        (answer) => answer.copyWith(
          firstSoundAfter: _now().difference(utterance.endedAt),
        ),
      ),
    );
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
        _showMedia(media);
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
        _newSpeaker().say(noServerAnswer);
        _notify(
          message: 'Brak odpowiedzi serwera. W nagłym wypadku dzwoń pod 112.',
        );
    }
  }

  void _showMedia(String? media) {
    if (media == _media) return;
    _media = media;
    _mediaSince = _now();
    final illustration = Illustrations.of(media);
    if (!illustration.hasMetronome) {
      _beatClock.stop();
    } else if (!_beatClock.isRunning) {
      _beatClock.start(illustration.period, _onBeat);
    }
    notifyListeners();
  }

  void _onBeat() {
    if (_disposed) return;
    _beats.add(null);
    if (metronomeAudible) unawaited(_metronome?.click());
    if (_reminderDue) _say(compressionReminder, reminder: true);
  }

  bool get _reminderDue {
    final last = _lastActivityAt;
    return last != null &&
        Illustrations.of(_media).hasMetronome &&
        _status == ConversationStatus.listening &&
        !_answerInProgress &&
        _waiting == null &&
        _partialText.isEmpty &&
        _now().difference(last) >= reminderAfter;
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
    _cancelTurnTimer();
    _listenTimer?.cancel();
    _beatClock.stop();
    _beats.close();
    _partials?.cancel();
    _recognized?.cancel();
    _answer?.cancel();
    _speaker?.stop();
    _input.dispose();
    _output.dispose();
    _assistant.dispose();
    _metronome?.dispose();
    _screenWake?.release();
    super.dispose();
  }
}
