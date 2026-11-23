import 'dart:convert';

import '../../domain/models/chat_message.dart';
import '../../domain/models/event_log_entry.dart';

class AskRequest {
  const AskRequest({
    required this.id,
    required this.text,
    required this.history,
    this.spokenAt,
  });

  final String id;
  final String text;
  final List<ChatMessage> history;
  final DateTime? spokenAt;

  String encode() => jsonEncode({
    'type': 'ask',
    'id': id,
    'text': text,
    'history': [
      for (final message in history)
        {'role': message.role.name, 'content': message.content},
    ],
    if (spokenAt != null) 'spoken_at': spokenAt!.toUtc().toIso8601String(),
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

  static ServerEvent? decode(String raw) {
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
      'action_logged' => ServerActionLogged(
        id: id,
        entry: _entry(
          json['entry'] as Map<String, dynamic>,
          json['label'] as String?,
        ),
      ),
      _ => null,
    };
  }

  static EventLogEntry _entry(Map<String, dynamic> json, String? label) =>
      EventLogEntry(
        id: json['id'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        elapsed: Duration(
          milliseconds: ((json['elapsed_s'] as num) * 1000).round(),
        ),
        action: json['action'] as String,
        transcript: json['transcript'] as String,
        label: label,
        confidence: (json['confidence'] as num?)?.toDouble(),
        source: json['source'] as String?,
      );
}

class ServerActionLogged extends ServerEvent {
  const ServerActionLogged({required String? id, required this.entry})
    : super(id);

  final EventLogEntry entry;
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
