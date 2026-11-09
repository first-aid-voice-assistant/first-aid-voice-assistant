# PoC mobile app

Demo mobile app of the first-aid voice assistant (Flutter, Android and iOS). **Status:** the test conversation works end to end – speech is recognised on the phone (Parakeet, Vosk or Whisper), every utterance goes to the [PoC server](../server) over a WebSocket, and the answer appears while it is generated and is read aloud sentence by sentence (system voice or Piper). You and the assistant take turns: when you stop speaking, the microphone switches off by itself and the assistant answers; when it has finished, tap the button to speak again ("Przerwij" stops it earlier). Why Flutter: [ADR 0001](../../docs/adr/0001-flutter-for-mobile-app.md).

| | |
|---|---|
| Package | `first_aid_voice_assistant` |
| Android application ID | `io.github.szymonliszewski.first_aid_voice_assistant` |
| iOS bundle ID | `io.github.szymonliszewski.firstAidVoiceAssistant` |
| Platforms | Android (arm64 phones), iOS (not built yet; needs a Mac with Xcode) |

## Scope of the demo

The demo checks that a voice conversation with the assistant works end to end.

| Screen / step | Status |
|---|---|
| **Start** – "demo version" banner, what the demo checks, button to the test conversation | done |
| **Test conversation** – tap to start, speak with pauses, tap to stop; text appears while speaking, every utterance becomes a message with its time and timings | done |
| Answers from the [PoC server](../server) over a WebSocket, shown while streamed and read aloud sentence by sentence; the microphone stops by itself when you finish and stays off while the assistant answers; "Przerwij" stops the answer | done |
| **Settings** – speech engine (Parakeet, Vosk, Whisper tiny / base / small) | done |
| Settings – voice (system / Piper) with "Odsłuchaj głos", server address | done |

Details: [docs/architecture.md](docs/architecture.md). Coding conventions: [docs/conventions.md](docs/conventions.md).

## Speech engines

All engines run on the phone and work offline after a one-time download.

| Engine | Library | Download | Notes |
|---|---|---|---|
| **Parakeet v3** (default) | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | ~670 MB | NVIDIA Parakeet TDT 0.6B v3, int8; 25 European languages, with punctuation |
| **Vosk small-pl** | [Vosk](https://alphacephei.com/vosk/) | ~53 MB (zip) | streaming, text appears immediately, no punctuation |
| **Whisper tiny / base / small** | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | ~33 / 61 / 191 MB | quantised (q5_1), tuned for speed |

Parakeet and Whisper also download the Silero voice activity detector (~0.6 MB), which finds speech in the recording.

| Model | Licence | Source |
|---|---|---|
| Parakeet TDT 0.6B v3 | CC-BY-4.0 (attribution: NVIDIA) | [csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8](https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8) |
| Silero VAD | MIT | [sherpa-onnx release assets](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models) |
| vosk-model-small-pl-0.22 | Apache-2.0 | [alphacephei.com/vosk/models](https://alphacephei.com/vosk/models) |
| Whisper (ggml, q5_1) | MIT | [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) |

Model files are not committed; the URLs, sizes and SHA-256 checksums are pinned in `lib/domain/models/speech_engine.dart`.

## Voices

| Voice | Library | Download | Notes |
|---|---|---|---|
| **System voice** (default) | [flutter_tts](https://pub.dev/packages/flutter_tts) | none | the phone's text-to-speech (Google / Apple); needs a Polish voice installed on the phone; sounds different on every phone |
| **Piper – Gosia** | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | ~67 MB (tar.bz2) | neural voice `pl_PL-gosia-medium`, the same on every phone, offline; played with [audioplayers](https://pub.dev/packages/audioplayers) |

| Model | Licence | Source |
|---|---|---|
| Piper `pl_PL-gosia-medium` | voice data CC0 ([model card](https://github.com/OHF-Voice/voice-datasets)); espeak-ng data GPL-3.0 | [sherpa-onnx release assets](https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models) |

## Setup (once)

1. Install the [Flutter SDK](https://docs.flutter.dev/install/archive) (stable), unpack it to a folder without spaces (e.g. `C:\Users\<you>\dev\flutter`) and add its `bin` folder to `PATH`.
2. Install the Android SDK with **Android SDK Platform 37.0**, **Android SDK Command-line Tools** and **NDK (Side by side) 29** (Android Studio → SDK Manager → "Show Package Details"). The NDK compiles the native speech libraries.
3. In VS Code install the **Flutter** extension.
4. Check the setup: `flutter doctor` – *Flutter* and *Android toolchain* must be green.

## Running

All commands are run from `poc/mobile/`.

```bash
flutter pub get
flutter run --release
```

In VS Code: pick the device in the status bar and press F5. Use a **real arm64 phone** (USB debugging on): the speech libraries ship no x86 build for the emulator, and the emulator's microphone and performance do not reflect real use. Measure speed in release (or profile) mode – debug builds are several times slower.

Server: start the [PoC server](../server) and set its address in **Settings → Serwer asystenta** – from an Android emulator `http://10.0.2.2:8000` (default), from a physical phone the computer's address in the same Wi-Fi network (e.g. `http://192.168.1.20:8000`, server started with `--host 0.0.0.0`). Without a model, `APP_CONFIG=configs/fake.yaml` streams a fixed Polish answer slowly, enough to try reading aloud and interrupting. When the phone is not in the computer's network, connect it by USB, run `adb reverse tcp:8000 tcp:8000` and use `http://127.0.0.1:8000`.

## First run

- The speech engine is chosen in **Settings** (default: Parakeet v3). When the test conversation opens with an engine that is not on the phone yet, the app downloads it once with a progress bar (use Wi-Fi for Parakeet); interrupted downloads resume and every file is checked against its size and SHA-256.
- The app asks for microphone access on the first tap of the talk button.
- iOS: the deployment target is 15.6. When CocoaPods creates `ios/Podfile` on a Mac, set `platform :ios, '15.6'` there too. The iOS build has not been tried yet.

## Checks

```bash
dart format .
flutter analyze
flutter test
```

## Structure

Layers follow the official Flutter architecture guide – see [docs/conventions.md](docs/conventions.md).

```
lib/
├── main.dart                 # entry point: creates the dependencies, runs the app
├── config/                   # dependencies.dart – builds the real services for the chosen engine (fakes in tests)
├── routing/                  # router.dart – route names and which screen each one opens
├── utils/                    # small shared helpers (times in Polish format, transcript clean-up, PCM conversion)
├── ui/                       # UI layer – feature-first
│   ├── core/                 #   app.dart (root widget), themes/, ui/ (shared widgets, demo banner)
│   └── <feature>/            #   start/, conversation/, settings/
│       ├── view_models/      #     state and logic of the screen (ChangeNotifier)
│       └── widgets/          #     <feature>_screen.dart and its widgets
├── data/                     # data layer – shared by features
│   ├── services/             #   wrap the outside world: microphone, speech libraries, TTS, audio player, WebSocket, downloads, phone storage
│   ├── repositories/         #   logic exposed to view models (speech input and output, assistant, answer speaker, settings)
│   └── model/                #   API models (WebSocket chat messages)
└── domain/
    └── models/               # app data types (Utterance, SpeechEngine, VoiceEngine, conversation entries)
test/                         # tests mirroring lib/ (ui/, data/, utils/); fakes/ – fake services shared by the tests
```

Other folders: `android/`, `ios/` (platform projects: microphone permission, dialer query for the 112 button, SDK 37.0, ProGuard rules for Vosk, iOS 15.6), `assets/illustrations/` (step illustrations, SVG, drawn for the project), `docs/` (architecture, conventions), `pubspec.yaml` (dependencies: sherpa_onnx, vosk_flutter_service, whisper_cpp_flutter_plus, record, flutter_tts, audioplayers, web_socket_channel, shared_preferences, path_provider, archive, crypto, flutter_svg, url_launcher).

Working rules: [AGENTS.md](AGENTS.md) and the project-wide [AGENTS.md](../../AGENTS.md).
