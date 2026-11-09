import 'package:first_aid_voice_assistant/config/dependencies.dart';
import 'package:first_aid_voice_assistant/data/repositories/assistant_repository.dart';
import 'package:first_aid_voice_assistant/domain/models/voice_engine.dart';
import 'package:first_aid_voice_assistant/ui/core/app.dart';
import 'package:first_aid_voice_assistant/ui/conversation/view_models/conversation_view_model.dart';
import 'package:first_aid_voice_assistant/ui/conversation/widgets/conversation_screen.dart';
import 'package:first_aid_voice_assistant/domain/models/speech_engine.dart';
import 'package:first_aid_voice_assistant/data/repositories/settings_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes/services.dart';

/// Phone-sized test screen (390 × 844 logical pixels, as in the mockups).
void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// The start screen scrolls when its content is taller than the screen.
Future<void> tapOnStartScreen(WidgetTester tester, String text) async {
  final target = find.text(text);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder svg(String file) => find.byWidgetPredicate(
  (widget) =>
      widget is SvgPicture &&
      widget.bytesLoader is SvgAssetLoader &&
      (widget.bytesLoader as SvgAssetLoader).assetName ==
          'assets/illustrations/cpr/$file',
);

void main() {
  late SettingsRepository settings;

  setUp(() async {
    settings = await SettingsRepository.load(MemoryStore());
  });

  late FakeChatSocket socket;
  late List<FakeSpeechOutput> outputs;
  late FakeEmergencyDialer dialer;

  setUp(() {
    socket = FakeChatSocket();
    outputs = [];
    dialer = FakeEmergencyDialer();
  });

  final inputs = <FakeSpeechInput>[];

  FakeSpeechInput speechInput() {
    final input = FakeSpeechInput(engine: settings.speechEngine);
    inputs.add(input);
    return input;
  }

  FakeSpeechOutput speechOutput(VoiceEngine voice) {
    final output = FakeSpeechOutput(label: voice.title);
    outputs.add(output);
    return output;
  }

  Widget app() => FirstAidApp(
    dependencies: AppDependencies(
      settings: settings,
      modelStore: FakeModelStore({SpeechEngine.parakeet}),
      createConversationViewModel: () => ConversationViewModel(
        input: speechInput(),
        output: speechOutput(settings.voiceEngine),
        assistant: AssistantRepository(
          socket: socket,
          serverUri: () => settings.chatUri,
        ),
        clock: () => DateTime(2026, 10, 27, 14, 21, 3),
      ),
      createSpeechOutput: speechOutput,
      emergencyDialer: dialer,
    ),
  );

  Future<void> askOnce(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tapOnStartScreen(tester, 'Rozpocznij rozmowę testową');
    await tester.tap(find.bySemanticsLabel('Zacznij mówić'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Zakończ mówienie'));
    await tester.pumpAndSettle();
  }

  testWidgets('start screen says it is a demo', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());

    expect(find.text('WERSJA DEMONSTRACYJNA'), findsOneWidget);
    expect(find.text('Asystent pierwszej pomocy'), findsOneWidget);
    expect(find.text('Rozpocznij rozmowę testową'), findsOneWidget);
  });

  testWidgets('start button opens the test conversation', (tester) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());

    await tapOnStartScreen(tester, 'Rozpocznij rozmowę testową');

    expect(find.text('Rozmowa testowa'), findsOneWidget);
    expect(find.text(firstPrompt), findsOneWidget);
    expect(find.textContaining('gotowe'), findsNothing);
  });

  testWidgets('tapping to start and to stop shows the recognised text', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());
    await tapOnStartScreen(tester, 'Rozpocznij rozmowę testową');

    await tester.tap(find.bySemanticsLabel('Zacznij mówić'));
    await tester.pumpAndSettle();
    expect(find.text('Naciśnij, aby zakończyć'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Zakończ mówienie'));
    await tester.pumpAndSettle();

    expect(find.text('Kolega nie oddycha'), findsOneWidget);
    expect(find.text('Poczekaj, aż asystent skończy'), findsOneWidget);
  });

  testWidgets('the answer appears in the middle while it is read aloud', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await askOnce(tester);

    socket.connection!.delta('Zadzwoń pod sto dwanaście. ');
    await tester.pumpAndSettle();

    expect(find.text('Zadzwoń pod sto dwanaście. '), findsOneWidget);
    expect(outputs.single.spoken, ['Zadzwoń pod sto dwanaście.']);
    expect(find.text('Przerwij'), findsOneWidget);

    socket.connection!.done('Zadzwoń pod sto dwanaście.');
    await tester.pumpAndSettle();
    expect(find.text('Zadzwoń pod sto dwanaście.'), findsOneWidget);
    expect(find.text('Przerwij'), findsNothing);
    expect(find.text('Naciśnij i mów'), findsOneWidget);
  });

  testWidgets('the history shows every message with its timings', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await askOnce(tester);
    socket.connection!.done('Zadzwoń pod sto dwanaście.');
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Historia rozmowy'));
    await tester.pumpAndSettle();

    expect(find.text('Historia rozmowy'), findsOneWidget);
    expect(find.text('głos po 1,0 s · model 0,1 s'), findsOneWidget);
    expect(find.text('14:21:02 · mowa 2,0 s · tekst po 0,3 s'), findsOneWidget);
  });

  testWidgets('the picture of the step is shown with a metronome for CPR', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await askOnce(tester);
    expect(svg('start.svg'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Rytm uciśnięć')), findsNothing);

    socket.connection!
      ..step('cpr/compressions')
      ..delta('Uciskaj mocno i szybko.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.bySemanticsLabel('Rytm uciśnięć 110 na minutę'),
      findsOneWidget,
    );
    expect(svg('compressions.svg'), findsOneWidget);
    expect(find.text('Uciskaj mocno i szybko.'), findsOneWidget);

    socket.connection!.done('Uciskaj mocno i szybko.');
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.bySemanticsLabel('Zacznij mówić'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.bySemanticsLabel('Zakończ mówienie'));
    await tester.pump(const Duration(milliseconds: 300));
    socket.connection!.step('cpr/head-tilt');
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.bySemanticsLabel(RegExp('Rytm uciśnięć')), findsNothing);
    expect(svg('head_tilt.svg'), findsOneWidget);
    expect(svg('compressions.svg'), findsNothing);
  });

  testWidgets('the 112 button opens the phone and is always there', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());
    await tapOnStartScreen(tester, 'Rozpocznij rozmowę testową');

    await tester.tap(find.bySemanticsLabel('Zadzwoń pod 112'));
    await tester.pumpAndSettle();
    expect(dialer.calls, 1);

    dialer.succeeds = false;
    await tester.tap(find.bySemanticsLabel('Zadzwoń pod 112'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Wybierz numer 112 ręcznie'), findsOneWidget);
  });

  testWidgets('the voice and the server are set in the settings', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());
    await tapOnStartScreen(tester, 'Ustawienia');

    final settingsList = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Piper – Gosia'),
      200,
      scrollable: settingsList,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Piper – Gosia'));
    await tester.pumpAndSettle();
    expect(settings.voiceEngine, VoiceEngine.piperGosia);

    await tester.scrollUntilVisible(
      find.text('Odsłuchaj głos'),
      200,
      scrollable: settingsList,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odsłuchaj głos'));
    await tester.pumpAndSettle();
    expect(outputs.last.label, 'Piper – Gosia');
    expect(outputs.last.spoken, isNotEmpty);
    expect(outputs.last.disposed, isTrue);

    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: settingsList,
    );
    await tester.enterText(find.byType(TextField), '192.168.1.20:8000');
    await tester.pumpAndSettle();
    expect(settings.serverAddress, '192.168.1.20:8000');
    expect(
      find.text('Połączenie: ws://192.168.1.20:8000/v1/chat'),
      findsOneWidget,
    );
  });

  testWidgets('the model chosen in the settings is used in the conversation', (
    tester,
  ) async {
    usePhoneScreen(tester);
    await tester.pumpWidget(app());

    await tapOnStartScreen(tester, 'Ustawienia');
    expect(find.text('pobrany'), findsOneWidget);
    await tester.ensureVisible(find.text('Whisper small'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Whisper small'));
    await tester.pumpAndSettle();
    expect(settings.speechEngine, SpeechEngine.whisperSmall);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tapOnStartScreen(tester, 'Rozpocznij rozmowę testową');

    expect(inputs.last.engine, SpeechEngine.whisperSmall);
  });
}
