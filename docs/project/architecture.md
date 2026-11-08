# System architecture

| | |
|---|---|
| **Created** | 2026-10-26 |
| **Version** | 0.4 |

## Overview

```
┌──────────────────────── PHONE ────────────────────────┐        ┌──────────── SERVER ────────────┐
│ microphone → VAD → ASR (on device)                    │        │ API → prompt → LLM provider ──▶ LLM (local container
│        │                                              │ request│        ▲                       │      or cloud API)
│        └──▶ transcript + end-of-utterance time ───────┼───────▶│        └── knowledge base       │
│                                                       │        │            (rules, scenarios)  │
│ event log (local DB) ◀── recognised actions ◀─────────┼────────┤                                │
│ screen + TTS        ◀── next step                     │response└────────────────────────────────┘
└───────────────────────────────────────────────────────┘
```

| Component | Where | Role | Implementation |
|---|---|---|---|
| Audio capture + VAD | phone | Continuous listening, splitting speech into utterances | `poc/mobile` (planned) |
| ASR | phone | Speech to text, works offline | compared in the PoC app: Parakeet (sherpa-onnx), Vosk, Whisper (whisper.cpp); choice after measurements on phones |
| API | server | Request and response formats between the phone and the server | WebSocket `WS /v1/chat` (streamed answer, cancelling); FastAPI / Pydantic models in `poc/server` |
| Server | server | Builds the prompt, calls the LLM, returns recognised actions and the next step | `poc/server` (FastAPI) |
| LLM | container or cloud | Recognises actions, chooses the next step from the scenario | LiteLLM adapter: Ollama, vLLM or commercial APIs |
| Knowledge base | repository | Vetted sources turned into an action dictionary and scenarios | `knowledge/` |
| Event log | phone | Timestamped record of recognised actions, export | `poc/mobile` (planned) |
| TTS | phone | Reads the answer aloud sentence by sentence while it is streamed; the microphone is off meanwhile, "Przerwij" stops it | compared in the PoC app: system TTS (`flutter_tts`) and Piper (sherpa-onnx) |
| Evaluation | repository | WER of ASR, agreement of the event log with the reference log, latency | `eval/` |

## Key decisions

- **The action state lives on the phone.** The app sends the event history and the current scenario step with every request, so the server keeps no sessions. This also makes it easier to move the LLM onto the phone later.
- **Timestamps are taken at the end of the utterance**, not when the answer arrives, so server latency does not distort the event log.
- **Answers are streamed and spoken while they are generated.** The user and the assistant take turns: the microphone stops by itself after a short pause and stays off while the assistant answers; "Przerwij" stops the answer, and the next question carries only the part that was actually spoken.
- **Models are swappable by configuration** (provider registry on the server), so that local and cloud models can be compared on the same corpus.

## Event log entry

> Draft – to be confirmed while building the demo.

The same format is used by the mobile app (event log), the server (recognised actions) and the evaluation (reference logs in `eval/`), so it is defined here once.

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Unique identifier of the entry |
| `timestamp` | string (ISO 8601 with time zone) | End of the utterance in which the action was reported |
| `elapsed_s` | number | Seconds since the first entry of the log (the start of the rescue) |
| `action` | string | Action code from the action dictionary in `knowledge/scenarios/` |
| `transcript` | string | Recognised text of the utterance; also carries details the code does not (e.g. "10 breaths") |
| `confidence` | number (0–1), optional | Confidence of the recognition; absent when the model reports none (LLM-based detection does not) |
| `source` | `local` / `cloud`, optional | Which model produced the result |

## Online and offline

| Function | Online | Offline |
|---|---|---|
| Speech recognition | cloud or on-device model | on-device model |
| Action recognition and prompts | large LLM | small local LLM (planned: e.g. a quantised Polish model on the phone) |
| Event log | yes | yes – phone clock |
| Voice prompts | yes | yes – system TTS or Piper on the phone |
| Log synchronisation | yes | after the network returns |
| Knowledge base and model updates | yes | no – last downloaded version |

In the current PoC the LLM runs on the server, so the offline mode is a later stage.

## Revision history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-10-26 | First version, based on the system concept document and the PoC |
| 0.2 | 2026-10-29 | ASR: three on-device engines compared in the PoC app instead of Whisper only |
| 0.3 | 2026-10-29 | WebSocket API with streamed answers; TTS on the phone (system voice, Piper); user and assistant take turns |
| 0.4 | 2026-11-08 | Event log entry: `elapsed_s` counts from the first entry; `confidence` and `source` are optional |
