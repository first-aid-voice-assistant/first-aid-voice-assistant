import 'utterance.dart';

sealed class ConversationEntry {
  const ConversationEntry();
}

class UserMessage extends ConversationEntry {
  const UserMessage(this.utterance);

  final Utterance utterance;
}

enum AnswerState { waiting, streaming, completed, interrupted, failed }

class AssistantMessage extends ConversationEntry {
  const AssistantMessage({
    this.text = '',
    this.state = AnswerState.waiting,
    this.spokenText = '',
    this.reminder = false,
    this.firstTokenTime,
    this.firstSoundAfter,
  });

  final String text;

  final AnswerState state;

  final String spokenText;

  final bool reminder;

  final Duration? firstTokenTime;

  final Duration? firstSoundAfter;

  bool get inProgress =>
      state == AnswerState.waiting || state == AnswerState.streaming;

  String? get heardByUser {
    final heard = switch (state) {
      AnswerState.completed => text,
      AnswerState.interrupted => spokenText,
      _ => '',
    };
    return heard.trim().isEmpty ? null : heard.trim();
  }

  AssistantMessage copyWith({
    String? text,
    AnswerState? state,
    String? spokenText,
    Duration? firstTokenTime,
    Duration? firstSoundAfter,
  }) => AssistantMessage(
    text: text ?? this.text,
    state: state ?? this.state,
    spokenText: spokenText ?? this.spokenText,
    reminder: reminder,
    firstTokenTime: firstTokenTime ?? this.firstTokenTime,
    firstSoundAfter: firstSoundAfter ?? this.firstSoundAfter,
  );
}
