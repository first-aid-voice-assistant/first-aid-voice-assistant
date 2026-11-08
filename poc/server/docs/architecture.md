# PoC server – architecture

| | |
|---|---|
| **Created** | 2026-10-26 |
| **Version** | 0.3 |

## Purpose

The PoC server is the part of the demo that talks to the language model. The mobile app sends it what the user said (a transcript) and gets back the assistant's answer. The server hides which model is used: open-source models in local containers and commercial APIs are interchangeable through configuration.

## Components

```
            ┌───────────────────────── app container (FastAPI) ─────────────────────────┐
request ──▶ │ api/  ──▶ pipeline/prompt.py ──▶ providers/registry ──▶ providers/llm/<name> │ ──▶ model
            │   ▲                                                                       │
            │   └── core/config.py (YAML config + .env settings), prompts/*.md          │
            └───────────────────────────────────────────────────────────────────────────┘
```

| Module | Responsibility |
|---|---|
| `app/main.py` | App factory (`create_app`): loads settings and the YAML config, builds the LLM provider, reads the system prompt, mounts the routers. |
| `app/core/config.py` | `Settings` (environment variables / `.env`) and `AppConfig` (YAML: ASR, LLM, RAG, prompts). |
| `app/api/rest.py` | Public endpoints: `GET /health`, `GET /v1/providers`. |
| `app/api/ws.py` | `WS /v1/chat`: the mobile app's chat – streams the answer, cancels it on request (see below). |
| `app/api/dev.py` | Dev-only `GET /dev` (test page) and `POST /dev/chat`, mounted only when `DEV_MODE=true`. |
| `app/pipeline/prompt.py` | Builds the message list: system prompt + history + user text. |
| `app/knowledge/` | Loads and validates `knowledge/` (`loader.py`, `models.py`), reads the wording of the guided conversation (`prompts.py`) and walks through a scenario one instruction at a time (`dialogue.py`). |
| `app/providers/base.py` | Provider interfaces and data types (`Message`, `LLMOptions`, `LLMDelta`, `LLMDone`, `LLMProvider`). |
| `app/providers/registry.py` | Maps the provider name from the config to a class (`@register_llm("<name>")`, `build_llm`). |
| `app/providers/llm/` | LLM adapters: `litellm` (Ollama, vLLM, commercial APIs) and `fake` (tests, no model; `delay` imitates a slow model). |
| `app/tools/pull_model.py` | One-shot command that pulls the configured Ollama model (`llm-pull` container). |

`app/providers/asr`, `tts`, `embeddings` and `app/rag` are placeholders for the next stages.

## Chat over a WebSocket (`WS /v1/chat`)

Used by the mobile app. Messages are JSON objects with a `type`.

| Direction | `type` | Fields | Meaning |
|---|---|---|---|
| app → server | `ask` | `id`, `text` (1–2000 chars), `history` (`[{role: user/assistant, content}]`, up to 50) | New question; cancels the answer in progress |
| app → server | `cancel` | `id` | Stop that answer (e.g. the user interrupted it) |
| server → app | `delta` | `id`, `text` | Next piece of the answer |
| server → app | `done` | `id`, `text`, `first_token_ms`, `total_ms` | Full answer and timings |
| server → app | `cancelled` | `id` | The answer was stopped |
| server → app | `error` | `id` (or `null` for an invalid message), `message` | The model failed or the message was invalid; the connection stays open |

1. `api/ws.py` reads messages in a loop; each `ask` starts a task that streams the answer, so the loop keeps reading and can cancel it.
2. `pipeline/prompt.py` builds `[system prompt, *history, question]`. The history comes from the app with every question; the only state the server keeps is the position in the scenario (see Guided scenarios), for as long as the connection lives.
3. Every `LLMDelta` is sent as `delta`; the final `LLMDone` as `done`. A model failure becomes `error`, so the app can say "call 112".
4. A new `ask`, a `cancel` or a closed connection cancels the streaming task, which stops the model call.

## Guided scenarios

The scenarios of `knowledge/` (state machines in YAML; steps may cite their sources) are the assistant's only source of procedures. The model never sees a whole procedure: the server walks through the scenario and tells the model, in every turn, the one thing to say next. This is what makes the assistant say one instruction, wait for the answer and only then give the next one.

1. At start-up `main.py` builds a `KnowledgeRuntime`: `load_knowledge` (path from `knowledge.path`) checks that every transition and action exists and that every step is reachable, and, if `knowledge/sources/` has files, that every cited source and section exists; `load_scenario_prompts` reads the wording from `prompts/scenario_v1.yaml`. Otherwise the server does not start. The rules from that file are appended once to the system prompt.
2. Every WebSocket connection gets its own `ScenarioDialogue` (`app/knowledge/dialogue.py`), which holds the cursor: scenario, step and the index of the next thing to say. Before every answer `begin_turn` returns the task for the model ("say this instruction", "repeat", "no procedure yet" or "the procedure is finished"), which `ws.py` appends to the system prompt of that turn. It stays one system message.
3. Inside a step the cursor moves on by itself: the user's next words are taken as "done". A step says its instructions one per turn, then its question (`asks`). When everything in a step has been said, a short side call to the model gets the user's answer and the numbered transitions of the step and returns one digit; `0`, a number out of range or any reply that is not a bare digit (punctuation around it is fine) means "no transition yet", and the assistant repeats instead of guessing. The first turn chooses the scenario the same way, from `trigger`.
4. The cursor moves only when the model has finished the answer, so an interrupted answer is said again.

Limits: the state lives only as long as the WebSocket connection (a reconnect restarts the scenario); the assistant assumes the user did what it asked when they speak again; each choice of a transition costs one extra model call before the answer starts. `POST /dev/chat` is stateless, so each request starts a scenario from its beginning.

## Request flow (`POST /dev/chat`)

1. `api/dev.py` validates the body (`{"text": "..."}`, 1–2000 characters).
2. `pipeline/prompt.py` builds `[system prompt, user text]` (no history – every request is a single turn).
3. The configured provider streams `LLMDelta` events and ends with exactly one `LLMDone` carrying the full answer.
4. The endpoint returns `{"answer", "elapsed_ms"}`. If the model fails, it returns HTTP 502 so the client can show its "call 112" fallback.

## Configuration

- `configs/*.yaml` select the providers and their parameters (`APP_CONFIG` picks the file): `base.yaml` (Docker), `gemma.yaml` (app on the host, Gemma 3 1B in the Ollama container), `bielik.yaml` (app on the host, Bielik 4.5B v3 in the Ollama container), `fake.yaml` (no model, streams a fixed Polish answer word by word with a delay – for UI work and trying the app; tests swap in an echoing fake).
- `knowledge: {enabled, path}` and `prompts.knowledge` turn on the scenarios from `knowledge/`; in Docker the folder is mounted read-only at `/knowledge`, which is where `../../knowledge` points from `/app`.
- `.env` holds secrets and environment settings (`DEV_MODE`, API keys, `REDIS_URL`).
- Experiments with other models go to `configs/experiments/`.

## Runtime (docker compose)

| Service | Role | Profile |
|---|---|---|
| `app` | FastAPI server | default |
| `redis` | Session store (not used yet) | default |
| `llm` | Ollama model server | default |
| `llm-pull` | Pulls the configured model once, then exits | default |
| `asr` | faster-whisper server with an OpenAI-compatible API | `local-asr` |
| `qdrant` | Vector database for RAG | `rag` |

`docker-compose.gpu.yml` adds GPU access to `llm` and `asr`.

## Not implemented yet

- ASR / audio input (in the demo, speech recognition is planned on the phone).
- Sessions that outlive a WebSocket connection (the scenario position is kept only per connection), the event log.
- Authentication of the WebSocket (PoC in a local network only).
- The analysis endpoint for the mobile app (recognised actions and the next step).
- RAG over the knowledge base.

## Revision history

| Version | Date | Changes |
|---|---|---|
| 0.1 | 2026-10-26 | First version, based on the existing code |
| 0.2 | 2026-10-29 | `WS /v1/chat` with streamed answers, cancelling and history sent by the app; `gemma.yaml`, `bielik.yaml`; `fake.yaml` streams a fixed answer slowly |
| 0.3 | 2026-10-29 | Guided scenarios: `app/knowledge/` (loader, validation, `ScenarioDialogue` that gives the model one instruction per turn), `prompts/scenario_v1.yaml`, `knowledge` config section; the server keeps the scenario position per WebSocket connection |
