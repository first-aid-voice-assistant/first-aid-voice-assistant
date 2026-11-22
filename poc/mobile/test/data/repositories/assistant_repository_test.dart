import 'dart:async';

import 'package:first_aid_voice_assistant/data/repositories/assistant_repository.dart';
import 'package:first_aid_voice_assistant/domain/models/chat_message.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../fakes/services.dart';

void main() {
  late FakeChatSocket socket;
  late AssistantRepository assistant;
  Uri? serverUri;

  setUp(() {
    socket = FakeChatSocket();
    serverUri = Uri.parse('ws://server:8000/v1/chat');
    assistant = AssistantRepository(
      socket: socket,
      serverUri: () => serverUri,
      answerTimeout: const Duration(milliseconds: 200),
    );
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('sends the question with the history and streams the answer', () async {
    final events = <AnswerEvent>[];
    assistant
        .ask(
          text: 'Nie oddycha',
          history: const [
            ChatMessage.user('Ktoś upadł'),
            ChatMessage.assistant('Czy oddycha?'),
          ],
        )
        .listen(events.add);
    await settle();

    final connection = socket.connection!;
    expect(socket.connectedTo.single.toString(), 'ws://server:8000/v1/chat');
    expect(connection.lastAsk['text'], 'Nie oddycha');
    expect(connection.lastAsk['history'], [
      {'role': 'user', 'content': 'Ktoś upadł'},
      {'role': 'assistant', 'content': 'Czy oddycha?'},
    ]);

    connection
      ..delta('Zacznij')
      ..delta(' uciskać.')
      ..done('Zacznij uciskać.');
    await settle();

    expect((events[0] as AnswerDelta).text, 'Zacznij');
    expect((events[1] as AnswerDelta).text, ' uciskać.');
    final done = events[2] as AnswerCompleted;
    expect(done.text, 'Zacznij uciskać.');
    expect(done.firstTokenTime, const Duration(milliseconds: 120));
  });

  test('passes on the picture of the step before the answer', () async {
    final events = <AnswerEvent>[];
    assistant.ask(text: 'Nie oddycha').listen(events.add);
    await settle();

    socket.connection!
      ..step('cpr/compressions')
      ..delta('Uciskaj.')
      ..emit({'type': 'action_logged', 'id': 'q1', 'entry': <String, Object>{}})
      ..done('Uciskaj.');
    await settle();

    expect((events[0] as AnswerStep).media, 'cpr/compressions');
    expect(events[1], isA<AnswerDelta>());
    expect(events[2], isA<AnswerCompleted>());
    expect(events, hasLength(3));
  });

  test('a new question ends the previous answer stream', () async {
    var firstClosed = false;
    assistant
        .ask(text: 'Pierwsze')
        .listen(null, onDone: () => firstClosed = true);
    await settle();
    final firstId = socket.connection!.lastAsk['id'];

    final events = <AnswerEvent>[];
    assistant.ask(text: 'Drugie').listen(events.add);
    await settle();
    socket.connection!
      ..emit({'type': 'delta', 'id': firstId, 'text': 'stare'})
      ..delta('nowe');
    await settle();

    expect(firstClosed, isTrue);
    expect(events.map((e) => (e as AnswerDelta).text), ['nowe']);
    expect(socket.connectedTo, hasLength(1));
  });

  test('cancel tells the server and ends the stream', () async {
    var closed = false;
    assistant.ask(text: 'hej').listen(null, onDone: () => closed = true);
    await settle();
    final id = socket.connection!.lastAsk['id'];

    await assistant.cancel();
    await settle();

    expect(closed, isTrue);
    expect(socket.connection!.sent.last, {'type': 'cancel', 'id': id});
  });

  test('fails when the server cannot be reached', () async {
    socket.connectError = Exception('refused');

    final events = await assistant.ask(text: 'hej').toList();

    expect(events.single, isA<AnswerFailed>());
  });

  test('fails for an invalid server address', () async {
    serverUri = null;

    final events = await assistant.ask(text: 'hej').toList();

    expect(events.single, isA<AnswerFailed>());
    expect(socket.connectedTo, isEmpty);
  });

  test('reports a server error for the question', () async {
    final events = <AnswerEvent>[];
    assistant.ask(text: 'hej').listen(events.add);
    await settle();
    socket.connection!.emit({
      'type': 'error',
      'id': socket.connection!.lastAsk['id'],
      'message': 'The model failed to answer',
    });
    await settle();

    expect((events.single as AnswerFailed).reason, contains('model failed'));
  });

  test(
    'fails when the connection drops and reconnects for the next question',
    () async {
      final events = <AnswerEvent>[];
      assistant.ask(text: 'hej').listen(events.add);
      await settle();
      await socket.connection!.drop();
      await settle();

      expect(events.single, isA<AnswerFailed>());

      assistant.ask(text: 'znowu');
      await settle();
      expect(socket.connectedTo, hasLength(2));
    },
  );

  test('fails when the server goes silent', () async {
    final completer = Completer<List<AnswerEvent>>();
    assistant.ask(text: 'hej').toList().then(completer.complete);

    final events = await completer.future;

    expect(events.single, isA<AnswerFailed>());
  });

  test('dispose closes the connection', () async {
    assistant.ask(text: 'hej');
    await settle();

    await assistant.dispose();

    expect(socket.connection!.closed, isTrue);
  });
}
