import '../data/repositories/assistant_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../data/repositories/speech_input.dart';
import '../data/repositories/speech_output.dart';
import '../data/services/audio_output.dart';
import '../data/services/chat_socket.dart';
import '../data/services/emergency_dialer.dart';
import '../data/services/metronome_sound.dart';
import '../data/services/key_value_store.dart';
import '../data/services/model_store.dart';
import '../data/services/parakeet_decoder.dart';
import '../data/services/screen_wake.dart';
import '../data/services/speech_segmenter.dart';
import '../data/services/speech_synthesizer.dart';
import '../data/services/streaming_recognizer.dart';
import '../data/services/text_to_speech.dart';
import '../data/services/voice_recorder.dart';
import '../data/services/whisper_decoder.dart';
import '../domain/models/speech_engine.dart';
import '../domain/models/voice_engine.dart';
import '../ui/conversation/view_models/conversation_view_model.dart';

class AppDependencies {
  const AppDependencies({
    required this.settings,
    required this.modelStore,
    required this.createConversationViewModel,
    required this.createSpeechOutput,
    required this.emergencyDialer,
  });

  static Future<AppDependencies> production() async {
    final modelStore = FileModelStore();
    final settings = await SettingsRepository.load(SharedPreferencesStore());
    return AppDependencies(
      settings: settings,
      modelStore: modelStore,
      createConversationViewModel: () => ConversationViewModel(
        input: _speechInput(settings.speechEngine, modelStore),
        output: _speechOutput(settings.voiceEngine, modelStore),
        assistant: AssistantRepository(
          socket: WebSocketChatSocket(),
          serverUri: () => settings.chatUri,
        ),
        metronome: AudioPlayersMetronomeSound(),
        screenWake: const WakelockScreenWake(),
      ),
      createSpeechOutput: (voice) => _speechOutput(voice, modelStore),
      emergencyDialer: const PhoneEmergencyDialer(),
    );
  }

  static SpeechInput _speechInput(SpeechEngine engine, ModelStore store) {
    return switch (engine.family) {
      EngineFamily.parakeet => SegmentedSpeechInput(
        engine: engine,
        store: store,
        recorder: MicrophoneVoiceRecorder(),
        segmenter: SileroSpeechSegmenter(),
        decoder: ParakeetDecoder(),
      ),
      EngineFamily.whisper => SegmentedSpeechInput(
        engine: engine,
        store: store,
        recorder: MicrophoneVoiceRecorder(),
        segmenter: SileroSpeechSegmenter(),
        decoder: WhisperDecoder(modelPath: engine.primaryModelPath),
      ),
      EngineFamily.vosk => StreamingSpeechInput(
        engine: engine,
        modelDirectory: SpeechEngine.voskModelDir,
        store: store,
        recorder: MicrophoneVoiceRecorder(),
        recognizer: VoskStreamingRecognizer(),
      ),
    };
  }

  static SpeechOutput _speechOutput(VoiceEngine voice, ModelStore store) {
    return switch (voice.family) {
      VoiceFamily.system => SystemSpeechOutput(tts: FlutterTextToSpeech()),
      VoiceFamily.piper => SynthesizedSpeechOutput(
        engine: voice,
        store: store,
        synthesizer: PiperSynthesizer(),
        audio: AudioPlayersOutput(),
      ),
    };
  }

  final SettingsRepository settings;

  final ModelStore modelStore;

  final ConversationViewModel Function() createConversationViewModel;

  final SpeechOutput Function(VoiceEngine voice) createSpeechOutput;

  final EmergencyDialer emergencyDialer;
}
