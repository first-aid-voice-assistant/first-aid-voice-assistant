import 'dart:convert';

import '../../domain/models/chat_message.dart';

class AskRequest {
  const AskRequest({
    required this.id,
    required this.text,
    required this.history,
  });

  final String id;
  final String text;
  final List<ChatMessage> history;

  String encode() => jsonEncode({
    'type': 'ask',
    'id': id,
    'text': text,
    'history': [
      for (final message in history)
        {'role': message.role.name, 'content': message.content},
    ],
  });
}

class CancelRequest {
  const CancelRequest(this.id);

  final String id;

  String encode() => jsonEncode({'type': 'cancel', 'id': id});
}

sealed class ServerEvent {
  const ServerEvent(this.id);

  final String? id;

  static ServerEvent decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('Server event is not an object');
    }
    final id = json['id'] as String?;
    return switch (json['type']) {
      'step' => ServerStep(id: id, media: json['media'] as String?),
      'delta' => ServerDelta(id: id, text: json['text'] as String),
      'done' => ServerDone(
        id: id,
        text: json['text'] as String,
        firstTokenMs: json['first_token_ms'] as int?,
        totalMs: json['total_ms'] as int,
      ),
      'cancelled' => ServerCancelled(id: id),
      'error' => ServerError(id: id, message: json['message'] as String),
      final type => throw FormatException('Unknown server event: $type'),
    };
  }
}

class ServerStep extends ServerEvent {
  const ServerStep({required String? id, required this.media}) : super(id);

  final String? media;
}

class ServerDelta extends ServerEvent {
  const ServerDelta({required String? id, required this.text}) : super(id);

  final String text;
}

class ServerDone extends ServerEvent {
  const ServerDone({
    required String? id,
    required this.text,
    required this.firstTokenMs,
    required this.totalMs,
  }) : super(id);

  final String text;
  final int? firstTokenMs;
  final int totalMs;
}

class ServerCancelled extends ServerEvent {
  const ServerCancelled({required String? id}) : super(id);
}

class ServerError extends ServerEvent {
  const ServerError({required String? id, required this.message}) : super(id);

  final String message;
}
