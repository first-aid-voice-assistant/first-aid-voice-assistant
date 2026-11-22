enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  const ChatMessage.user(this.content) : role = ChatRole.user;

  const ChatMessage.assistant(this.content) : role = ChatRole.assistant;

  final ChatRole role;

  final String content;
}

sealed class AnswerEvent {
  const AnswerEvent();
}

class AnswerStep extends AnswerEvent {
  const AnswerStep(this.media);

  final String? media;
}

class AnswerDelta extends AnswerEvent {
  const AnswerDelta(this.text);

  final String text;
}

class AnswerCompleted extends AnswerEvent {
  const AnswerCompleted({
    required this.text,
    required this.firstTokenTime,
    required this.totalTime,
  });

  final String text;

  final Duration? firstTokenTime;

  final Duration totalTime;
}

class AnswerFailed extends AnswerEvent {
  const AnswerFailed(this.reason);

  final String reason;
}
