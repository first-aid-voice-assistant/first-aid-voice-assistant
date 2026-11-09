import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/models/chat_message.dart';
import '../model/chat_protocol.dart';
import '../services/chat_socket.dart';

class AssistantRepository {
  AssistantRepository({
    required this._socket,
    required this._serverUri,
    this.connectTimeout = const Duration(seconds: 5),
    this.answerTimeout = const Duration(seconds: 30),
  });

  final ChatSocket _socket;
  final Uri? Function() _serverUri;
  final Duration connectTimeout;
  final Duration answerTimeout;

  ChatConnection? _connection;
  Future<ChatConnection>? _connecting;
  StreamSubscription<String>? _incoming;
  _PendingAnswer? _active;
  int _asked = 0;
  bool _disposed = false;

  Stream<AnswerEvent> ask({
    required String text,
    List<ChatMessage> history = const [],
  }) {
    final previous = _active;
    if (previous != null) _finish(previous);
    final answer = _PendingAnswer('q${++_asked}');
    _active = answer;
    unawaited(
      _send(answer, AskRequest(id: answer.id, text: text, history: history)),
    );
    return answer.events.stream;
  }

  Future<void> cancel() async {
    final answer = _active;
    if (answer == null) return;
    _finish(answer);
    try {
      _connection?.send(CancelRequest(answer.id).encode());
    } catch (e) {
      debugPrint('Cancelling the answer failed: $e');
    }
  }

  Future<void> _send(_PendingAnswer answer, AskRequest request) async {
    try {
      final connection = await _ensureConnected();
      if (_active != answer) return;
      connection.send(request.encode());
      _armTimeout(answer);
    } catch (e) {
      _fail(answer, 'Cannot reach the server: $e');
    }
  }

  Future<ChatConnection> _ensureConnected() {
    final connection = _connection;
    if (connection != null) return Future.value(connection);
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<ChatConnection> _open() async {
    final uri = _serverUri();
    if (uri == null) {
      throw const AssistantException('Invalid server address');
    }
    final connection = await _socket.connect(uri, timeout: connectTimeout);
    if (_disposed) {
      await connection.close();
      throw const AssistantException('Assistant disposed');
    }
    _connection = connection;
    _incoming = connection.incoming.listen(
      _onMessage,
      onError: (Object error) => _onClosed(),
      onDone: _onClosed,
    );
    return connection;
  }

  void _onClosed() {
    _incoming = null;
    _connection = null;
    final answer = _active;
    if (answer != null) _fail(answer, 'Connection closed');
  }

  void _onMessage(String raw) {
    final ServerEvent event;
    try {
      event = ServerEvent.decode(raw);
    } catch (e) {
      debugPrint('Unexpected server message: $e');
      return;
    }
    final answer = _active;
    if (answer == null || event.id != answer.id) {
      if (event is ServerError) debugPrint('Server error: ${event.message}');
      return;
    }
    switch (event) {
      case ServerStep(:final media):
        answer.events.add(AnswerStep(media));
        _armTimeout(answer);
      case ServerDelta(:final text):
        answer.events.add(AnswerDelta(text));
        _armTimeout(answer);
      case ServerDone(:final text, :final firstTokenMs, :final totalMs):
        answer.events.add(
          AnswerCompleted(
            text: text,
            firstTokenTime: firstTokenMs == null
                ? null
                : Duration(milliseconds: firstTokenMs),
            totalTime: Duration(milliseconds: totalMs),
          ),
        );
        _finish(answer);
      case ServerError(:final message):
        _fail(answer, message);
      case ServerCancelled():
        _finish(answer);
    }
  }

  void _armTimeout(_PendingAnswer answer) {
    answer.timeout?.cancel();
    answer.timeout = Timer(
      answerTimeout,
      () => _fail(answer, 'No answer for ${answerTimeout.inSeconds} s'),
    );
  }

  void _fail(_PendingAnswer answer, String reason) {
    if (_active != answer) return;
    debugPrint('Answer failed: $reason');
    answer.events.add(AnswerFailed(reason));
    _finish(answer);
  }

  void _finish(_PendingAnswer answer) {
    if (_active == answer) _active = null;
    answer.timeout?.cancel();
    if (!answer.events.isClosed) answer.events.close();
  }

  Future<void> dispose() async {
    _disposed = true;
    final answer = _active;
    if (answer != null) _finish(answer);
    await _incoming?.cancel();
    _incoming = null;
    await _connection?.close();
    _connection = null;
  }
}

class AssistantException implements Exception {
  const AssistantException(this.message);

  final String message;

  @override
  String toString() => 'AssistantException: $message';
}

class _PendingAnswer {
  _PendingAnswer(this.id);

  final String id;
  final StreamController<AnswerEvent> events = StreamController<AnswerEvent>();
  Timer? timeout;
}
