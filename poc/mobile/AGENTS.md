# PoC mobile app – agent instructions

Project-wide rules (language, domain and safety, data, documentation) are in the root [`AGENTS.md`](../../AGENTS.md); this file adds the rules specific to the mobile app. Run all commands from `poc/mobile/`.

Status: start screen, on-device speech recognition with three selectable engines (Parakeet via sherpa-onnx, Vosk, Whisper via whisper.cpp), answers from the PoC server over a WebSocket, read aloud sentence by sentence while they are streamed (system voice or Piper). The conversation is hands-free: a spoken greeting, the microphone switches off while the assistant speaks and on again by itself, the CPR metronome beats through the compression step.

## Safety in this part

- The "call 112" button is always visible and works without the backend.
- When the server is unreachable or returns an error, the app says so plainly and points the user to 112. It never shows an invented instruction.
- The app must not take its own voice for the user's words: the microphone input is muted from the first sound of any speech of the assistant until 0.3 s after it ends (the recorder keeps running; utterances that overlap the muted time are dropped). Keep this for every new kind of speech (it goes through `ConversationViewModel._newSpeaker`).
- The assistant never stops itself because of speech (no barge-in); only "Przerwij" stops it.
- The compression reminder only repeats what the knowledge base already says (keep compressing in the rhythm of the beep); new spoken instructions belong in `knowledge/`, not in the app.

## Rules

- Requests to the server and responses from it follow the server API (Pydantic models in `poc/server`, browsable at `/docs` of the running server). Event-log entries follow `docs/project/architecture.md`.
- Event timestamps are taken at the **end of the utterance**, not when the server answers – otherwise server latency distorts the times compared with the reference log in the evaluation.
- The conversation and the event history are kept in the app and sent with every request. For now the PoC server also keeps the current scenario step for the length of one WebSocket connection (a reconnect restarts the scenario); moving the step to the app and sending it with every request is the target. An interrupted answer goes into the history only as far as it was spoken.
- Model files (speech recognition and voice weights) are not committed; their URLs, sizes and SHA-256 checksums are pinned in `lib/domain/models/speech_engine.dart` and `voice_engine.dart` and listed in `README.md`.
- No comments in `lib/`; the code should explain itself through names. Non-obvious build workarounds in `android/` keep a short comment.
- Coding conventions: [docs/conventions.md](docs/conventions.md).

## Definition of done

`flutter analyze` and `flutter test` pass, the code is formatted with `dart format`, and `README.md` / `docs/` are updated if the structure or behaviour changed.
