# PoC server – agent instructions

Project-wide rules (language, domain and safety, data, documentation) are in the root [`AGENTS.md`](../../AGENTS.md); this file adds the rules specific to the server. Run all commands from `poc/server/`.

Voice assistant backend (ASR → LLM, with RAG as a disabled, optional stage). A modular monolith (FastAPI) plus open-source models in separate containers (Ollama/vLLM, faster-whisper server) or commercial APIs behind the same provider interfaces. There is no audio/ASR layer on the server: the mobile app recognises speech and talks to the model over `WS /v1/chat` (streamed answer, cancelling, history sent with every question); the dev-only `POST /dev/chat` is for quick tests.

Status: streamed chat over a WebSocket for the mobile app (LiteLLM + fake providers; the app keeps the conversation, the server keeps the position in the first-aid scenario for the length of one connection). Not yet: ASR/audio, sessions that outlive a connection, event log, authentication.

## Safety in this part

- The system prompt (`prompts/system_v1.md`) carries the safety rules from the root `AGENTS.md`. `prompts/scenario_v1.yaml` is part of the prompt the model gets; the same applies to it. Do not weaken or remove the rules; any prompt change must be re-checked against them.
- Errors must surface as an explicit error response so that clients can show their "call 112" fallback.

## Dev client

With `DEV_MODE=true` the app serves a test page at `/dev` and `POST /dev/chat` (`{"text": "..."}` → `{"answer", "elapsed_ms"}`); `scripts/chat_client.py` is the terminal equivalent. The endpoint is stateless and has no auth, so it must stay dev-only.

## Directory map

- `app/api/` – REST, the chat WebSocket (`ws.py`), dev test endpoint/page; `app/core/` – config, logging
- `app/pipeline/` – prompt building (orchestration comes later); `app/knowledge/` – loads and validates the scenarios of `knowledge/` and walks through them one instruction at a time (`dialogue.py`)
- `app/providers/` – interfaces (`base.py`), registry (`registry.py`), adapters in `asr/ llm/ embeddings/ tts/`
- `app/rag/` – empty for now (planned: `Retriever` + `NullRetriever`)
- `configs/` – `base.yaml`, `experiments/`; `prompts/` – system prompt and `scenario_v1.yaml` (wording of the guided conversation)
- `tests/unit`, `tests/contract`
- `docs/` – architecture and coding conventions of the server
- Shared with other parts (repository root): `knowledge/`, `eval/`

## Commands

```
uv sync                                   # dependencies
APP_CONFIG=configs/fake.yaml uv run uvicorn app.main:app --reload   # no model needed: slow fixed Polish answer (PowerShell: $env:APP_CONFIG=...)
uv run python scripts/chat_client.py "..."                         # terminal test client
docker compose up --build                 # app + redis + Ollama (pulls the default model once)
docker compose --profile local-asr up                              # + local ASR server
uv run pytest
uv run ruff check . && uv run ruff format --check .
uv run mypy app
```

## Skills

Templates in `.claude/skills/` (`add-llm-provider`, `add-asr-provider`, `swap-model`, `run-eval`, `add-knowledge-source`, `add-local-model-service`). Each is marked as a template to finish; complete them as the pieces they depend on appear.

## Rules

- Pipeline and API code never import concrete providers; new models go through the registry plus a config entry only.
- Every provider must pass the contract tests (`tests/contract`).
- Secrets live only in `.env` (template: `.env.example`).
- Prompts live in `prompts/`, not in code.
- Request and response models used by the mobile app are its API: change them deliberately and update the mobile app in the same pull request. Event-log entries follow `docs/project/architecture.md`.
- A model change means a new config in `configs/experiments/` plus an entry in the evaluation results table (`eval/results/` at the repository root).
- Coding conventions: [docs/conventions.md](docs/conventions.md).

## Definition of done

Tests, ruff and mypy pass; an example config is added; an evaluation results entry is added if the change concerns a model; `README.md` and `docs/` are updated if the structure or behaviour changed.
