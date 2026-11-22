import 'package:first_aid_voice_assistant/data/repositories/assistant_repository.dart';
import 'package:first_aid_voice_assistant/data/repositories/speech_output.dart';
import 'package:first_aid_voice_assistant/domain/models/conversation_entry.dart';
import 'package:first_aid_voice_assistant/ui/conversation/view_models/conversation_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../fakes/services.dart';

void main() {
  late FakeSpeechInput input;
  late FakeSpeechOutput output;
  late FakeChatSocket socket;
  late ConversationViewModel viewModel;
  late FakeMetronomeSound metronome;
  var now = DateTime(2026, 10, 27, 14, 21, 3);

  ConversationViewModel build({
    Duration endOfTurn = const Duration(hours: 1),
  }) => ConversationViewModel(
    input: input,
    output: output,
    assistant: AssistantRepository(
      socket: socket,
      serverUri: () => Uri.parse('ws://server:8000/v1/chat'),
    ),
    metronome: metronome,
    endOfTurn: endOfTurn,
    clock: () => now,
  );

  setUp(() {
    now = DateTime(2026, 10, 27, 14, 21, 3);
    input = FakeSpeechInput();
    output = FakeSpeechOutput();
    metronome = FakeMetronomeSound();
    socket = FakeChatSocket();
    viewModel = build();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  Future<FakeChatConnection> askFirstQuestion() async {
    await viewModel.initialize();
    await viewModel.toggleRecording();
    await viewModel.toggleRecording();
    await settle();
    return socket.connection!;
  }

  List<Map<String, dynamic>> asks() =>
      socket.connection!.sent.where((m) => m['type'] == 'ask').toList();

  test('is ready after the model is prepared', () async {
    await viewModel.initialize();

    expect(viewModel.status, ConversationStatus.ready);
    expect(viewModel.modelLabel, 'Parakeet v3');
    expect(viewModel.voiceLabel, 'Głos systemowy');
  });

  test('fails with a message when the voice cannot be prepared', () async {
    output.prepareError = const MissingVoiceException('pl-PL');

    await viewModel.initialize();

    expect(viewModel.status, ConversationStatus.failed);
    expect(viewModel.preparingLabel, 'Głos systemowy');
    expect(viewModel.message, contains('polskiego głosu'));
  });

  test('reports the model download progress', () async {
    input.downloadSteps = [0.1, 0.5, 1.0];
    final progress = <double?>[];
    viewModel.addListener(() => progress.add(viewModel.downloadProgress));

    await viewModel.initialize();

    expect(progress, containsAllInOrder([0.1, 0.5, 1.0]));
    expect(viewModel.downloadProgress, isNull);
    expect(viewModel.status, ConversationStatus.ready);
  });

  test('fails with a message when the model cannot be prepared', () async {
    input.prepareError = Exception('no network');

    await viewModel.initialize();

    expect(viewModel.status, ConversationStatus.failed);
    expect(viewModel.message, isNotNull);
    expect(viewModel.canRecord, isFalse);
  });

  test('the first tap starts recording and the second one stops it', () async {
    await viewModel.initialize();

    await viewModel.toggleRecording();
    expect(viewModel.isRecording, isTrue);
    expect(input.listening, isTrue);

    await viewModel.toggleRecording();
    expect(viewModel.status, ConversationStatus.ready);
    expect(input.listening, isFalse);
    expect(viewModel.utterances.single.text, 'Kolega nie oddycha');
  });

  test('adds every utterance as soon as it is recognised', () async {
    await viewModel.initialize();
    await viewModel.toggleRecording();

    input.emitUtterance('Uciskam klatkę');
    input.emitUtterance('Podłączam AED');
    await Future<void>.delayed(Duration.zero);

    expect(viewModel.isRecording, isTrue);
    expect(viewModel.utterances.map((u) => u.text), [
      'Uciskam klatkę',
      'Podłączam AED',
    ]);
  });

  test(
    'shows the partial text while recording and clears it afterwards',
    () async {
      await viewModel.initialize();
      await viewModel.toggleRecording();

      input.emitPartial('Kolega nie');
      await Future<void>.delayed(Duration.zero);
      expect(viewModel.partialText, 'Kolega nie');

      await viewModel.toggleRecording();
      expect(viewModel.partialText, isEmpty);
    },
  );

  test('shows a message when no speech was recognised', () async {
    input.text = '';
    await viewModel.initialize();

    await viewModel.toggleRecording();
    await viewModel.toggleRecording();

    expect(viewModel.utterances, isEmpty);
    expect(viewModel.message, isNotNull);
  });

  test('stays usable after a recognition error', () async {
    input.finishError = Exception('decoder failed');
    await viewModel.initialize();

    await viewModel.toggleRecording();
    await viewModel.toggleRecording();

    expect(viewModel.utterances, isEmpty);
    expect(viewModel.status, ConversationStatus.ready);
    expect(viewModel.message, isNotNull);
  });

  test('ignores taps while recording is starting', () async {
    await viewModel.initialize();

    final starting = viewModel.toggleRecording();
    await viewModel.toggleRecording();
    await starting;

    expect(viewModel.isRecording, isTrue);
  });

  test('does not record without microphone access', () async {
    input.permission = false;
    await viewModel.initialize();

    await viewModel.toggleRecording();

    expect(viewModel.status, ConversationStatus.ready);
    expect(input.listening, isFalse);
    expect(viewModel.message, contains('mikrofonu'));
  });

  test(
    'stops listening by itself after a pause and asks the question',
    () async {
      viewModel = build(endOfTurn: const Duration(milliseconds: 20));
      input.text = '';
      await viewModel.initialize();
      await viewModel.toggleRecording();

      input.emitUtterance('Kolega nie oddycha');
      await settle();
      expect(viewModel.isRecording, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(viewModel.isRecording, isFalse);
      expect(input.listening, isFalse);
      expect(asks().single['text'], 'Kolega nie oddycha');
    },
  );

  test(
    'speaking again during the pause keeps listening and asks it all together',
    () async {
      viewModel = build(endOfTurn: const Duration(milliseconds: 40));
      input.text = '';
      await viewModel.initialize();
      await viewModel.toggleRecording();

      input.emitUtterance('Kolega upadł');
      await settle();
      input.emitPartial('i nie');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(viewModel.isRecording, isTrue);

      input.emitUtterance('i nie oddycha');
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(viewModel.isRecording, isFalse);
      expect(asks().single['text'], 'Kolega upadł i nie oddycha');
    },
  );

  test(
    'streams the answer and speaks each sentence as soon as it is complete',
    () async {
      final connection = await askFirstQuestion();
      expect(connection.lastAsk['text'], 'Kolega nie oddycha');
      expect(connection.lastAsk['history'], isEmpty);
      expect(viewModel.assistantActivity, AssistantActivity.thinking);

      connection.delta('Zadzwoń pod sto dwanaście.');
      await settle();
      expect(viewModel.answers.single.text, 'Zadzwoń pod sto dwanaście.');
      expect(viewModel.answers.single.state, AnswerState.streaming);
      expect(output.spoken, isEmpty);

      connection.delta(' Czy');
      await settle();
      expect(output.spoken, ['Zadzwoń pod sto dwanaście.']);

      connection
        ..delta(' oddycha?')
        ..done('Zadzwoń pod sto dwanaście. Czy oddycha?');
      await settle();

      final answer = viewModel.answers.single;
      expect(output.spoken, ['Zadzwoń pod sto dwanaście.', 'Czy oddycha?']);
      expect(answer.state, AnswerState.completed);
      expect(answer.firstTokenTime, const Duration(milliseconds: 120));
      expect(answer.firstSoundAfter, const Duration(seconds: 1));
      expect(viewModel.assistantActivity, AssistantActivity.idle);
    },
  );

  test('the next question carries the whole answer in the history', () async {
    final connection = await askFirstQuestion();
    connection.done('Czy oddycha?');
    await settle();

    input.text = 'Nie oddycha';
    await viewModel.toggleRecording();
    await viewModel.toggleRecording();
    await settle();

    expect(asks().last['text'], 'Nie oddycha');
    expect(asks().last['history'], [
      {'role': 'user', 'content': 'Kolega nie oddycha'},
      {'role': 'assistant', 'content': 'Czy oddycha?'},
    ]);
  });

  test('cannot start talking until the assistant has finished', () async {
    output.holdSentences = true;
    final connection = await askFirstQuestion();
    expect(viewModel.canRecord, isFalse);
    connection
      ..delta('Sprawdź oddech. ')
      ..done('Sprawdź oddech. ');
    await settle();
    expect(viewModel.assistantActivity, AssistantActivity.speaking);

    await viewModel.toggleRecording();
    expect(viewModel.isRecording, isFalse);
    expect(output.stops, 0);

    output.finishSentence();
    await settle();
    expect(viewModel.canRecord, isTrue);
    await viewModel.toggleRecording();
    expect(viewModel.isRecording, isTrue);
  });

  test(
    'after the stop button the next question gets only what was heard',
    () async {
      output.holdSentences = true;
      final connection = await askFirstQuestion();
      connection.delta('Sprawdź oddech. Odchyl mu głowę. ');
      await settle();

      await viewModel.stopAnswer();
      expect(viewModel.answers.single.state, AnswerState.interrupted);
      expect(viewModel.answers.single.spokenText, 'Sprawdź oddech.');

      input.text = 'On oddycha';
      await viewModel.toggleRecording();
      await viewModel.toggleRecording();
      await settle();

      expect(asks().last['history'], [
        {'role': 'user', 'content': 'Kolega nie oddycha'},
        {'role': 'assistant', 'content': 'Sprawdź oddech.'},
      ]);
    },
  );

  test(
    'the stop button silences the answer and cancels it on the server',
    () async {
      output.holdSentences = true;
      final connection = await askFirstQuestion();
      connection.delta('Sprawdź oddech. ');
      await settle();

      await viewModel.stopAnswer();

      expect(output.stops, 1);
      expect(viewModel.assistantActivity, AssistantActivity.idle);
      expect(connection.sent.last['type'], 'cancel');
    },
  );

  test('says to call 112 when the server does not answer', () async {
    socket.connectError = Exception('refused');
    await viewModel.initialize();
    await viewModel.toggleRecording();
    await viewModel.toggleRecording();
    await settle();

    expect(viewModel.answers.single.state, AnswerState.failed);
    expect(viewModel.answers.single.text, noServerAnswer);
    expect(output.spoken.join(' '), noServerAnswer);
    expect(viewModel.message, contains('112'));
  });

  test(
    'shows the picture of the step and how long it has been shown',
    () async {
      final connection = await askFirstQuestion();
      expect(viewModel.media, isNull);
      expect(viewModel.latestUserText, 'Kolega nie oddycha');

      connection
        ..step('cpr/compressions')
        ..delta('Uciskaj mocno.');
      await settle();
      now = now.add(const Duration(seconds: 40));

      expect(viewModel.media, 'cpr/compressions');
      expect(viewModel.mediaShownFor, const Duration(seconds: 40));
      expect(viewModel.latestAnswer, 'Uciskaj mocno.');
    },
  );

  test('the same picture in the next turn keeps its time', () async {
    final connection = await askFirstQuestion();
    connection
      ..step('cpr/compressions')
      ..done('Uciskaj mocno.');
    await settle();
    now = now.add(const Duration(seconds: 30));

    await viewModel.toggleRecording();
    await viewModel.toggleRecording();
    await settle();
    connection.step('cpr/compressions');
    await settle();

    expect(viewModel.mediaShownFor, const Duration(seconds: 30));
  });

  test(
    'the metronome sounds only for compressions while nobody speaks',
    () async {
      output.holdSentences = true;
      final connection = await askFirstQuestion();
      connection
        ..step('cpr/compressions')
        ..delta('Uciskaj mocno. ')
        ..done('Uciskaj mocno. ');
      await settle();

      viewModel.onMetronomeBeat();
      expect(metronome.clicks, 0, reason: 'the assistant is speaking');

      output.finishSentence();
      await settle();
      viewModel.onMetronomeBeat();
      expect(metronome.clicks, 1);

      await viewModel.toggleRecording();
      viewModel.onMetronomeBeat();
      expect(metronome.clicks, 1, reason: 'the user is speaking');
    },
  );

  test('the metronome is silent outside compressions', () async {
    final connection = await askFirstQuestion();
    connection
      ..step('cpr/head-tilt')
      ..done('Odegnij głowę.');
    await settle();

    viewModel.onMetronomeBeat();

    expect(viewModel.metronomeAudible, isFalse);
    expect(metronome.clicks, 0);
  });

  test('dispose releases the voice and the connection', () async {
    await askFirstQuestion();

    viewModel.dispose();
    await settle();

    expect(output.disposed, isTrue);
    expect(metronome.disposed, isTrue);
    expect(socket.connection!.closed, isTrue);
  });
}
