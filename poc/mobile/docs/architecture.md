# PoC mobile app – architecture

| | |
|---|---|
| **Created** | 2026-10-26 |
| **Version** | 1.2 |

> Status: the whole demo loop works – on-device speech recognition with three selectable engines, answers from the PoC server over a WebSocket, read aloud while they are streamed (system voice or Piper); the conversation is hands-free (spoken greeting, the microphone switches on and off by itself around the assistant's speech, continuous CPR metronome).

## Goal of the demo

The demo checks that a voice conversation with the assistant works end to end:

1. **Speech recognition** – a speech model on the phone turns speech into text, while the user speaks.
2. **Model answer** – the text goes to the PoC server, the language model answers.
3. **Voice answer** – the answer is read aloud.

## Flow

```
greeting (spoken) ─▶ microphone (16 kHz, on while the assistant is silent) ─▶ speech engine ─▶ utterances ─▶ counting / fillers ─▶ ignored
        ▲                                                                                        │ accepted
        │ on again 0.3 s after the speech                                                        ▼
speaker ◀── TTS, sentence by sentence ◀── delta … done ◀── PoC server (LLM) ◀── ask ◀── 1.2 s without speech
   (microphone off from the first sound to the end; never interrupted by speech)
metronome 110/min (own clock, whole compression step) + reminder after 60 s of silence
```

## Screens

| Screen | Content | Status |
|---|---|---|
| Start | "Demo version" banner, what the demo checks, "Start test conversation" button, note about 112 | done |
| Test conversation | engine and voice status only while they are being prepared or failed (the chosen engine and voice are in the settings); centred: the start picture (a person talking to the phone) until the first step, then the illustration of the current step (from the server's `step` event, animated, with a 110/min metronome and elapsed time for compressions) and the assistant's latest answer in large type, growing while streamed; below it, centred like the answer, the user's last or partial words; status line ("Asystent myśli / mówi…") with "Przerwij"; bottom row: "112" (opens the phone dialer, works without the server), listening indicator in the middle ("Słucham", grows while the user speaks; "Mówi asystent" while the microphone is off for the assistant's speech; a button only without microphone access – "Włącz mikrofon"), "Historia" | done |
| History (bottom sheet) | one message per utterance with its time and timings, assistant answers with "głos po X s · model Y s", "przerwano", "przypomnienie"; the spoken greeting is the first message; counting aloud is not shown; updates live | done |
| Settings | speech engine (Parakeet, Vosk, Whisper tiny / base / small); voice (system / Piper) with "Odsłuchaj głos"; server address | done |

## Speech engines

| Engine | Speech detection | Recognition | `SpeechInput` | Libraries |
|---|---|---|---|---|
| Parakeet v3 (default) | Silero VAD | Parakeet TDT 0.6B v3 int8 (offline transducer) | `SegmentedSpeechInput` | sherpa-onnx |
| Whisper tiny / base / small | Silero VAD | Whisper ggml q5_1 | `SegmentedSpeechInput` | sherpa-onnx (VAD), whisper.cpp |
| Vosk small-pl | built into Vosk | Kaldi streaming model | `StreamingSpeechInput` | Vosk |

The engine is chosen in the settings; the conversation uses the engine chosen when it opens. `AppDependencies` builds the matching `SpeechInput`, so the view model and the screens do not depend on the engine.

## Modules

| Module | File | Responsibility | Status |
|---|---|---|---|
| Entry point and wiring | `lib/main.dart`, `lib/config/dependencies.dart` | creates the real services and repositories (`AppDependencies`) and picks the `SpeechInput` for the engine; tests build the app with fakes | done |
| Navigation | `lib/routing/router.dart` | route names, which screen each one opens | done |
| App shell | `lib/ui/core/` | root widget, theme, shared "demo" widgets | done |
| Start | `lib/ui/start/widgets/start_screen.dart` | start screen | done |
| Conversation | `lib/ui/conversation/` | `ConversationViewModel` (state, `ChangeNotifier`): spoken greeting, listening that stops while the assistant speaks and starts again afterwards, end of the user's turn, utterances → one question, counting filter, answers → screen and `AnswerSpeaker`, "Przerwij", fallback, metronome beats and the compression reminder; `ConversationScreen` | done |
| Settings | `lib/ui/settings/`, `lib/data/repositories/settings_repository.dart` | settings screen; `SettingsRepository` keeps the speech engine, the voice and the server address, saved with `KeyValueStore` (`shared_preferences`) | done |
| Speech input | `lib/data/repositories/speech_input.dart` | `SpeechInput` interface (partial text, stream of utterances, muting); `SegmentedSpeechInput` (microphone → VAD → transcriber → decoder) and `StreamingSpeechInput` (microphone → Vosk); both turn results into `Utterance` | done |
| Live transcription | `lib/data/repositories/segmented_transcriber.dart` | `SegmentedTranscriber`: decodes the utterance in progress for the partial text, decodes each finished speech region once for the message; one decode at a time; keeps only the last 30 s of audio (and any speech still waiting to be decoded), so listening for a whole rescue does not fill the memory | done |
| Voice recorder | `lib/data/services/voice_recorder.dart` | `VoiceRecorder` interface; `MicrophoneVoiceRecorder` (package `record`): 16 kHz mono PCM stream | done |
| Speech detection | `lib/data/services/speech_segmenter.dart` | `SpeechSegmenter` interface; `SileroSpeechSegmenter` (sherpa-onnx): finished speech regions and the start of the one in progress | done |
| Decoders | `lib/data/services/segment_decoder.dart`, `parakeet_decoder.dart`, `whisper_decoder.dart` | `SegmentDecoder` interface (samples → text); `ParakeetDecoder` (sherpa-onnx in a worker isolate); `WhisperDecoder` (whisper.cpp with speed settings) | done |
| Streaming recognizer | `lib/data/services/streaming_recognizer.dart` | `StreamingRecognizer` interface; `VoskStreamingRecognizer`: partial text, results with word times | done |
| Model files | `lib/data/services/model_store.dart` | `ModelStore` interface; `FileModelStore`: download of all files of an engine with progress, timeouts, resume (HTTP `Range`), retries, size and SHA-256 check, zip extraction | done |
| Domain models | `lib/domain/models/` | `Utterance` (recognised utterance with timings), `SpeechEngine` and `VoiceEngine` (with their files, sizes and SHA-256), `ChatMessage` and `AnswerEvent`, conversation entries (`UserMessage`, `AssistantMessage`) | done |
| Helpers | `lib/utils/` | times in Polish format; transcript clean-up; PCM bytes → samples; sentence splitter (Polish abbreviations) and markdown clean-up for reading aloud; WAV encoding; server address → WebSocket address; counting aloud and fillers (`counting.dart`) | done |
| Assistant client | `lib/data/services/chat_socket.dart`, `lib/data/model/chat_protocol.dart`, `lib/data/repositories/assistant_repository.dart` | `ChatSocket` (package `web_socket_channel`); `AssistantRepository`: connects lazily and reconnects, sends `ask` with the history, turns server events into a stream of `AnswerEvent`s per question, `cancel`, timeouts (5 s to connect, 30 s without an event) | done |
| Speech output | `lib/data/repositories/speech_output.dart` | `SpeechOutput` interface (`prepare`, `prefetch`, `speak`, `stop`); `SystemSpeechOutput` (needs a `pl-PL` system voice); `SynthesizedSpeechOutput` (download → Piper → WAV → player; prepares the next sentence while the current one plays) | done |
| TTS services | `lib/data/services/text_to_speech.dart`, `speech_synthesizer.dart`, `audio_output.dart` | `FlutterTextToSpeech` (`flutter_tts`, completion via handlers); `PiperSynthesizer` (sherpa-onnx `OfflineTts` in a worker isolate); `AudioPlayersOutput` (`audioplayers`, speaker, mixes with recording) | done |
| Step illustrations | `lib/domain/models/illustration.dart`, `lib/ui/conversation/widgets/step_illustration.dart`, `assets/illustrations/cpr/` | `Illustrations`: picture name from the scenario (`cpr/compressions`) → SVG files (a still base and an optional moving overlay) and the kind of movement (press at 110/min with a metronome, pulse, none); no picture yet shows the start drawing, unknown names the scene. Movements: press (compressions, with the metronome), shake (shaking the shoulders), tilt (head tilt and chin lift, rotation around the neck), breathe (chest rising), pulse (hints such as sound waves or a target). `StepIllustration` animates the overlay with one `AnimationController`; on the compression picture each press is started by a beat of the metronome clock, so the picture and the beep share the beat; package `flutter_svg` | all 14 pictures of adult BLS in an instructional style with short captions (hand-written SVG files, edited directly; drafts for medical review) |
| Metronome sound | `lib/data/services/metronome_sound.dart`, `assets/sounds/metronome_click.wav` | `MetronomeSound`; `AudioPlayersMetronomeSound` plays a 40 ms beep (1.6 kHz, short fade in and out) in the low-latency mode of `audioplayers`; the sound is set once and every beat stops and resumes it, because replaying it with `play` in that mode only resumes the finished sound, so after the first beep the metronome was silent | done |
| Metronome clock | `lib/data/services/beat_clock.dart` | `BeatClock`; `TimerBeatClock`: a beat every period counted from the start (no drift from timer delays), independent of the screen and of the conversation | done |
| Screen | `lib/data/services/screen_wake.dart` | `ScreenWake`; `WakelockScreenWake` (package `wakelock_plus`) keeps the screen on while the conversation is open | done |
| Emergency call | `lib/data/services/emergency_dialer.dart` | `EmergencyDialer`; `PhoneEmergencyDialer` opens the dialer with 112 (package `url_launcher`, `tel:`); a failure shows "Wybierz numer 112 ręcznie" | done |
| Answer speaker | `lib/data/repositories/answer_speaker.dart` | `AnswerSpeaker`: takes the streamed text, speaks complete sentences in order, knows what was spoken, stops at once | done |
| Settings check | `lib/ui/settings/view_models/voice_check_view_model.dart` | "Odsłuchaj głos": prepares the chosen voice (downloads Piper) and reads a test sentence | done |

Services wrap one library or device each and are hidden behind interfaces; repositories combine them and hold the logic. The view model is tested with fakes (`test/fakes/`) and a service can be swapped without touching the UI.

Naming note: in this guide a *repository* holds the logic and a *service* wraps an outside source – roughly the reverse of the Spring-style backend layering (controller → service → repository).

## Key behaviour

- **Hands-free:** once the models are ready the assistant says "Powiedz, co się stało. Słucham cały czas." and the microphone starts by itself when it has finished; it listens for the whole conversation except while the assistant speaks; the screen stays on. There is no talk or mute button. Without microphone access the conversation waits, and a tap tries again.
- **One message per utterance:** a pause of about 0.5 s ends an utterance; it becomes a message at once, while recording continues. Continuous speech is split after 10 s.
- **Timestamps:** an utterance is stamped with the moment its speech ended, computed from its position in the recording – not with the end of recognition. This matches the rule for the event log. "tekst po X s" is the time from the end of the speech to the text.
- **Only speech is decoded (Parakeet, Whisper):** Silero VAD marks speech; silence and pauses never reach the decoder, which prevents Whisper from inventing text from silence and saves battery. While someone speaks, the utterance in progress is decoded about every 0.5 s for the partial text; a finished utterance is decoded once more in full. Only one decode runs at a time, so delays do not pile up.
- **Vosk:** audio goes to Vosk chunk by chunk; Vosk returns partial text and detects the end of an utterance itself. Message times come from Vosk word times.
- **Whisper settings:** language `pl`, greedy decoding (best-of 1, beam 1, no temperature fallback), no context, single segment, no timestamps, 4 threads, audio context proportional to the utterance length; utterances shorter than 1.1 s are padded with silence.
- **Model download:** an engine is downloaded once on first use, file by file, streamed to `.part` files with a progress bar; a stalled download (30 s without data) times out, an interrupted one resumes with HTTP `Range`, up to 3 attempts; a file is accepted only with the exact size and SHA-256 pinned in `SpeechEngine`; the Vosk zip is extracted and deleted. The models are loaded once when the conversation opens and warmed up with one second of silence. After the download recognition works offline.
- **Transcript clean-up:** tags in square brackets are removed, a transcript that is only a sound description such as "(muzyka)" is dropped, and repetition loops are collapsed (a word 4+ times or a 2–3-word phrase 3+ times in a row).
- **Answer while it is generated:** every utterance is sent at once as an `ask` with the conversation history. Streamed text is added to the assistant's message on the screen and split into sentences; a sentence is spoken as soon as the next one starts (or the answer ends), so the first sentence is heard while the model is still writing. Piper prepares the next sentence while the current one plays.
- **History:** the app keeps the conversation. Consecutive messages of the same speaker are joined; an interrupted answer is included only as far as it was spoken; answers that were not heard are left out. Words said before the answer starts are therefore asked together with the previous ones.
- **Taking turns:** after each utterance the app waits 1.2 s; new speech (partial text) keeps the turn open, otherwise everything said in the turn is asked as one question – the microphone stays on.
- **Microphone muted while the assistant speaks:** the recording runs for the whole conversation (started once, after the greeting). At the first sound of any speech of the assistant (answer, greeting, reminder, no-server message) the input is muted: the recogniser gets silence and any utterance that overlaps the muted time is dropped (also the one in progress); 0.3 s after the speech has ended the input is live again. Muting instead of stopping and starting the recorder avoids a recorder that did not start again after a stop on the phone. The assistant therefore never hears itself and the phone stays in its normal audio mode (media volume, loudspeaker). The assistant is never stopped by speech; "Przerwij" stops it by hand ("przerwano", cancelled on the server). Words recognised while an answer is still being prepared (nothing audible yet) cancel it on the server and are asked together with the previous ones.
- **Compression reminder:** after 60 s of compressions without a word from the user or the assistant, the app says "Uciskaj dalej w rytm sygnału." (marked "przypomnienie" in the history), then again after the next silent minute. It only repeats what the scenario already says; it is never said while someone speaks or an answer is on its way.
- **Counting aloud and fillers:** an utterance made only of number words or digits (counting compressions) or of sounds such as "yyy", "mhm" is ignored; one that reaches "trzydzieści" / "30" is asked, because it says thirty compressions are done.
- **Reading aloud:** markdown marks and list numbers are removed before a sentence is spoken (small models ignore the "no markdown" rule of the prompt); the screen shows the text as received.
- **Timings shown:** "głos po X s" – from the end of the user's speech to the first sound of the answer; "model Y s" – time to the first token on the server.
- **Step picture:** the server sends `step` with the picture name before each answer; the picture stays until a different one arrives, so the metronome and its elapsed time run on while the user keeps doing compressions over several turns. Without the scenarios (or before one is chosen) the scene is shown. The picture names come from `knowledge/scenarios/`; a test checks that every name used there has an illustration.
- **Metronome:** while the compression picture is shown, the metronome clock (`TimerBeatClock`) beats 110/min without a break – also while the user or the assistant speaks, like the voice prompts of an AED; each beat beeps and starts one press of the picture. The beep is 40 ms long, shorter than the 0.25 s of speech the VAD needs, so it does not start an utterance while the microphone listens.
- **No server:** a failed connection, a server error or 30 s without an event ends the answer with a fixed message that is also spoken: no connection, call 112.
- **Privacy:** no recorded audio is written to disk (Piper's synthesized sentences may pass through a temporary file on iOS).
- **Errors:** a failed download, missing microphone access or a recognition error is shown in Polish and the screen stays usable.

## Revision history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-10-26 | Planned design of the demo app |
| 0.2 | 2026-10-27 | Flutter project created; link to ADR 0001 |
| 0.3 | 2026-10-27 | Simplified demo (start, test conversation, settings); start screen and on-device speech recognition implemented |
| 0.4 | 2026-10-27 | Settings screen with the choice of the Whisper model; own model download with progress |
| 0.5 | 2026-10-27 | Code structure aligned with the official Flutter architecture guide (ui / data / domain, config, routing, utils) |
| 0.6 | 2026-10-28 | Live recognition mode, verified and resumable model downloads, transcript clean-up |
| 0.7 | 2026-10-28 | File recognition mode removed; live recognition only |
| 0.8 | 2026-10-29 | Three speech engines (Parakeet via sherpa-onnx, Vosk, Whisper via whisper.cpp); Silero VAD so that only speech is decoded; one message per utterance; tap to start and stop |
| 0.9 | 2026-10-29 | Server connection over a WebSocket; answers shown and read aloud while streamed; two voices (system, Piper); turn taking with automatic end of the user's turn; settings for voice and server |
| 1.0 | 2026-11-08 | Step screen: illustration of the current step (`step` event) with animation and metronome, latest answer in the middle, conversation history in a bottom sheet, "112" button |
| 1.1 | 2026-11-09 | Metronome beeps in the rhythm of the compressions while nobody speaks |
| 1.2 | 2026-11-09 | Hands-free conversation: spoken greeting, microphone off while the assistant speaks and on again by itself (listening indicator instead of a talk button), counting filter, metronome on its own clock through the whole compression step, compression reminder, screen kept on, transcriber keeps only recent audio |
