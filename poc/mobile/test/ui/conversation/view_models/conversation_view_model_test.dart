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
  late FakeMetronomeSound metronome;
  late FakeBeatClock beatClock;
  late FakeScreenWake screenWake;
  late ConversationViewModel viewModel;
  var now = DateTime(2026, 10, 27, 14, 21, 3);

  ConversationViewModel build({Duration endOfTurn = Duration.zero}) =>
      ConversationViewModel(
        input: input,
        output: output,
        assistant: AssistantRepository(
          socket: socket,
          serverUri: () => Uri.parse('ws://server:8000/v1/chat'),
        ),
        metronome: metronome,
        beatClock: beatClock,
        screenWake: screenWake,
        endOfTurn: endOfTurn,
        listenAgain: Duration.zero,
        clock: () => now,
      );

  setUp(() {
    now = DateTime(2026, 10, 27, 14, 21, 3);
    input = FakeSpeechInput();
    output = FakeSpeechOutput();
    metronome = FakeMetronomeSound();
    beatClock = FakeBeatClock();
    screenWake = FakeScreenWake();
    socket = FakeChatSocket();
    viewModel = build();
  });

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  List<Map<String, dynamic>> asks() =>
      socket.connection?.sent.where((m) => m['type'] == 'ask').toList() ??
      const [];

  Future<void> start() async {
    await viewModel.initialize();
    await settle();
  }

  Future<void> say(String text) async {
    input.emitUtterance(text);
    await settle();
  }

  Future<FakeChatConnection> askFirstQuestion() async {
    await start();
    await say('Kolega nie oddycha');
    return socket.connection!;
  }

  Future<void> speakAnswer(FakeChatConnection connection, String text) async {
    output.holdSentences = true;
    connection.done(text);
    await settle();
  }

  group('start', () {
    test('says the greeting aloud and then listens by itself', () async {
      await start();

      expect(output.spoken, ['Powiedz, co się stało.', 'Słucham cały czas.']);
      expect(viewModel.latestAnswer, greeting);
      expect(viewModel.status, ConversationStatus.listening);
      expect(input.listening, isTrue);
      expect(screenWake.on, isTrue);
    });

    test('the microphone waits until the greeting has been said', () async {
      output.holdSentences = true;

      await start();
      expect(viewModel.pauseReason, PauseReason.assistantSpeaking);
      expect(viewModel.canResume, isFalse);
      expect(input.listening, isFalse);

      output.finishSentence();
      await settle();
      output.finishSentence();
      await settle();
      expect(viewModel.status, ConversationStatus.listening);
    });

    test('reports the model download progress', () async {
      input.downloadSteps = [0.1, 0.5, 1.0];
      final progress = <double?>[];
      viewModel.addListener(() => progress.add(viewModel.downloadProgress));

      await start();

      expect(progress, containsAllInOrder([0.1, 0.5, 1.0]));
      expect(viewModel.downloadProgress, isNull);
    });

    test('fails with a message when the model cannot be prepared', () async {
      input.prepareError = Exception('no network');

      await start();

      expect(viewModel.status, ConversationStatus.failed);
      expect(viewModel.message, isNotNull);
      expect(output.spoken, isEmpty);
      expect(input.listening, isFalse);
    });

    test('fails with a message when the voice cannot be prepared', () async {
      output.prepareError = const MissingVoiceException('pl-PL');

      await start();

      expect(viewModel.status, ConversationStatus.failed);
      expect(viewModel.preparingLabel, 'Głos systemowy');
      expect(viewModel.message, contains('polskiego głosu'));
    });

    test(
      'without microphone access it waits and tries again on a tap',
      () async {
        input.permission = false;

        await start();

        expect(viewModel.pauseReason, PauseReason.microphoneUnavailable);
        expect(viewModel.message, contains('mikrofonu'));

        input.permission = true;
        await viewModel.resume();
        expect(viewModel.status, ConversationStatus.listening);
      },
    );
  });

  group('turns', () {
    test(
      'an utterance is asked after a short silence, without a tap',
      () async {
        await askFirstQuestion();

        expect(asks().single['text'], 'Kolega nie oddycha');
        expect(asks().single['history'], [
          {'role': 'assistant', 'content': greeting},
        ]);
        expect(viewModel.assistantActivity, AssistantActivity.thinking);
        expect(input.listening, isTrue);
      },
    );

    test('utterances of one turn are asked together', () async {
      viewModel = build(endOfTurn: const Duration(milliseconds: 40));
      await start();

      input
        ..emitUtterance('Kolega upadł')
        ..emitUtterance('i nie oddycha');
      await settle();
      expect(asks(), isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(asks().single['text'], 'Kolega upadł i nie oddycha');
    });

    test('speech in progress keeps the turn open', () async {
      viewModel = build(endOfTurn: const Duration(milliseconds: 40));
      await start();

      input
        ..emitUtterance('Kolega upadł')
        ..emitPartial('i chyba');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(asks(), isEmpty);
      expect(viewModel.latestUserText, 'i chyba');

      input.emitUtterance('i chyba nie oddycha');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(asks().single['text'], 'Kolega upadł i chyba nie oddycha');
    });

    test(
      'the microphone is muted while the assistant speaks and on again after',
      () async {
        final connection = await askFirstQuestion();
        await speakAnswer(connection, 'Zadzwoń pod sto dwanaście.');

        expect(viewModel.assistantActivity, AssistantActivity.speaking);
        expect(viewModel.pauseReason, PauseReason.assistantSpeaking);
        expect(input.muted, isTrue);

        output.finishSentence();
        await settle();

        expect(viewModel.status, ConversationStatus.listening);
        expect(input.muted, isFalse);
        expect(input.listening, isTrue);
        expect(input.cancelled, 0);
      },
    );

    test('the next question carries the whole answer in the history', () async {
      final connection = await askFirstQuestion();
      connection.done('Zadzwoń pod sto dwanaście.');
      await settle();

      await say('Dzwonię');

      expect(asks().last['history'], [
        {'role': 'assistant', 'content': greeting},
        {'role': 'user', 'content': 'Kolega nie oddycha'},
        {'role': 'assistant', 'content': 'Zadzwoń pod sto dwanaście.'},
      ]);
    });

    test(
      'new words before the answer is heard ask again with all of them',
      () async {
        await askFirstQuestion();

        await say('Leży na chodniku');

        final sent = socket.connection!.sent;
        expect(sent.where((m) => m['type'] == 'cancel'), hasLength(1));
        expect(asks().last['text'], 'Kolega nie oddycha Leży na chodniku');
        expect(viewModel.answers, hasLength(2));
      },
    );

    test('counting aloud is not asked, reaching thirty is', () async {
      await start();

      await say('dwadzieścia jeden, dwadzieścia dwa, 23');
      expect(socket.connection, isNull);
      expect(viewModel.utterances, isEmpty);

      await say('dwadzieścia dziewięć, trzydzieści');
      expect(asks().single['text'], 'dwadzieścia dziewięć, trzydzieści');
    });

    test('"Przerwij" stops the answer and listens again', () async {
      final connection = await askFirstQuestion();
      await speakAnswer(connection, 'Zadzwoń pod sto dwanaście.');

      await viewModel.stopAnswer();
      await settle();

      expect(viewModel.answers.last.state, AnswerState.interrupted);
      expect(viewModel.status, ConversationStatus.listening);
    });

    test('says to call 112 when the server does not answer', () async {
      socket.connectError = Exception('refused');
      await start();

      await say('Kolega nie oddycha');

      expect(viewModel.answers.last.state, AnswerState.failed);
      expect(output.spoken.join(' '), contains('numer sto dwanaście'));
      expect(viewModel.message, contains('112'));
      expect(viewModel.status, ConversationStatus.listening);
    });

    test('the answer time is measured from the end of speech', () async {
      final connection = await askFirstQuestion();
      now = now.add(const Duration(milliseconds: 500));

      connection.done('Zadzwoń pod sto dwanaście.');
      await settle();

      expect(
        viewModel.answers.last.firstSoundAfter,
        const Duration(milliseconds: 1500),
      );
    });
  });

  group('metronome', () {
    test(
      'beats through the compressions, also while the assistant speaks',
      () async {
        final connection = await askFirstQuestion();
        connection.step('cpr/compressions');
        await settle();
        expect(beatClock.isRunning, isTrue);
        expect(beatClock.period, const Duration(microseconds: 545454));

        beatClock.beat();
        await speakAnswer(connection, 'Uciskaj mocno i szybko.');
        beatClock.beat();

        expect(metronome.clicks, 2);
      },
    );

    test('stops outside compressions', () async {
      final connection = await askFirstQuestion();
      connection.step('cpr/compressions');
      await settle();

      connection.step('cpr/head-tilt');
      await settle();

      expect(beatClock.isRunning, isFalse);
      expect(viewModel.metronomeAudible, isFalse);
    });

    test(
      'reminds to keep going after a minute of compressions in silence',
      () async {
        final connection = await askFirstQuestion();
        connection
          ..step('cpr/compressions')
          ..done('Uciskaj mocno i szybko.');
        await settle();

        now = now.add(const Duration(seconds: 30));
        beatClock.beat();
        expect(output.spoken.last, 'Uciskaj mocno i szybko.');

        now = now.add(const Duration(seconds: 31));
        beatClock.beat();
        await settle();

        expect(output.spoken.last, compressionReminder);
        expect(viewModel.answers.last.reminder, isTrue);
        expect(viewModel.status, ConversationStatus.listening);

        now = now.add(const Duration(seconds: 30));
        beatClock.beat();
        expect(
          output.spoken.where((text) => text == compressionReminder),
          hasLength(1),
        );
      },
    );

    test('no reminder while the user is speaking', () async {
      final connection = await askFirstQuestion();
      connection
        ..step('cpr/compressions')
        ..done('Uciskaj.');
      await settle();
      now = now.add(const Duration(minutes: 2));

      input.emitPartial('jestem już');
      await settle();
      beatClock.beat();

      expect(output.spoken, isNot(contains(compressionReminder)));
    });

    test('the same picture in the next turn keeps its time', () async {
      final connection = await askFirstQuestion();
      connection.step('cpr/compressions');
      await settle();
      now = now.add(const Duration(seconds: 30));

      connection.done('Uciskaj.');
      await settle();
      await say('Uciskam');
      connection.step('cpr/compressions');
      await settle();

      expect(viewModel.mediaShownFor, const Duration(seconds: 30));
    });
  });

  test('dispose releases the voice, the screen and the connection', () async {
    final connection = await askFirstQuestion();
    connection.step('cpr/compressions');
    await settle();

    viewModel.dispose();
    await settle();

    expect(output.disposed, isTrue);
    expect(metronome.disposed, isTrue);
    expect(connection.closed, isTrue);
    expect(screenWake.on, isFalse);
    expect(beatClock.isRunning, isFalse);
  });
}
