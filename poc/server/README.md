# PoC server

Test server of the first-aid voice assistant: it receives a transcript of what the user said and returns the model's answer (ASR → LLM, with room for RAG). Every model (open-source, self-hosted or a commercial API) can be swapped by changing the config.

> **Disclaimer.** This is a research prototype, not a medical device. Its answers are not medically validated and it does not replace emergency services. In a real emergency call **112**.

All commands below are run from `poc/server/`.

## Architecture in brief

- Modular monolith (FastAPI) – one `app` container.
- Open-source models in separate containers (Ollama/vLLM, faster-whisper server), enabled via compose profiles.
- Commercial models behind the same provider interfaces (LiteLLM adapter).
- API: `GET /health`, `GET /v1/providers`, `WS /v1/chat` (the mobile app's chat: the answer is streamed and can be cancelled; the app sends the conversation history with every question; with the scenarios on, a `step` event first names the picture of the current instruction) and the dev-only `POST /dev/chat` for testing the LLM with ready-made transcripts.
- No audio/ASR on the server: speech is recognised on the phone.
- Event log (`event_log.enabled`, off in the shipped configs): the server recognises which rescue actions the user reports and sends each as an `action_logged` event with a timestamp (`spoken_at` from the app); the phone keeps the log ([ADR 0002](../../docs/adr/0002-event-log-detection.md)).
- The first-aid scenarios from `knowledge/` (adult BLS, choking) guide the conversation (`knowledge.enabled`): the server keeps the position in the scenario per WebSocket connection and gives the model one instruction per turn. RAG is disabled (`rag.enabled: false`), Qdrant sits behind the `rag` profile.

More: [docs/architecture.md](docs/architecture.md). Coding conventions: [docs/conventions.md](docs/conventions.md).

## Structure

```
poc/server/
├── app/                      # backend (FastAPI)
│   ├── main.py               # app factory, wiring
│   ├── api/                  # REST endpoints, chat WebSocket (ws.py), dev-only test endpoint and page (static/)
│   ├── core/                 # config loading (env + YAML)
│   ├── pipeline/             # prompt building, short side calls to the model (completion.py)
│   ├── eventlog/             # event log: entry model, action detector, recorder
│   ├── knowledge/            # loads and validates knowledge/ (scenarios), steps through them (dialogue.py)
│   ├── providers/            # model adapters
│   │   ├── base.py           # provider interfaces
│   │   ├── registry.py       # provider name from config -> class
│   │   ├── llm/              # LiteLLM adapter, fake LLM for tests
│   │   └── asr/ tts/ embeddings/   # empty for now
│   ├── rag/                  # empty for now
│   └── tools/                # helper commands (e.g. pulling the Ollama model)
├── configs/                  # base.yaml, fake.yaml, gemma.yaml, bielik.yaml, qwen.yaml, experiments/ (one config per model),
│                             # modelfiles/ (Ollama Modelfiles), domain_terms.txt
├── prompts/                  # system prompt, scenario wording, event log prompt (versioned files)
├── scripts/                  # chat_client.py (one-shot test client), chat_repl.py (interactive chat over WS /v1/chat)
├── tests/                    # unit/ and contract/ (same tests for every provider)
├── docs/                     # architecture and coding conventions of the server
├── .claude/skills/           # agent skill templates (to be finished)
├── docker-compose.yml        # app, redis, Ollama (+ model pull); profiles: local-asr, rag
├── docker-compose.gpu.yml    # GPU override
├── Dockerfile
├── pyproject.toml, uv.lock   # dependencies (uv)
├── .env.example              # settings and API keys template
└── AGENTS.md, CLAUDE.md      # rules for working on the server
```

The knowledge base (`knowledge/`) and the evaluation (`eval/`) live at the repository root, because they are shared with the mobile app and the target application.

## Requirements

- Python 3.12+, [uv](https://docs.astral.sh/uv/)
- Docker + Docker Compose (GPU: NVIDIA Container Toolkit)

## Running

```bash
docker compose up --build
```

This starts the app, Redis and Ollama and downloads the model named in the config on the first run; the app starts once the model is ready, so the first start takes a few minutes. The default config is set in `docker-compose.yml` (`APP_CONFIG`), currently `configs/experiments/qwen25-7b-compose.yaml` (Qwen2.5 7B Instruct Q4_K_M, ~4.7 GB; with a 4 GB GPU it runs mostly on the CPU, use the GPU override below). For a light start use `APP_CONFIG=configs/base.yaml` (`gemma3:1b`, ~0.8 GB). Configs of models built from a Modelfile (Bielik 7B v0.1) need a different command, see "Models built from a Modelfile" below. `.env` is optional (`cp .env.example .env` to change settings).

Then open **http://localhost:8000/dev**, paste a transcript and send it. Or use the terminal client:

```bash
uv run python scripts/chat_client.py "Mój kolega nie oddycha, co mam robić?"
```

Without a model (a fixed Polish answer streamed slowly, handy for UI work):

```powershell
$env:APP_CONFIG = "configs/fake.yaml"; uv run uvicorn app.main:app --reload
```

Running the app locally against the Ollama container: `$env:APP_CONFIG = "configs/gemma.yaml"` (Gemma 3 1B), `"configs/qwen.yaml"` (Qwen2.5 7B, needs the GPU override) or `"configs/bielik.yaml"` (Bielik 4.5B v3; pull it once with `docker compose exec llm ollama pull hf.co/speakleash/Bielik-4.5B-v3.0-Instruct-GGUF:Q8_0`).

### Talking to the assistant

`POST /dev/chat` (the `/dev` page and `chat_client.py`) is stateless: every request starts the scenario from the beginning. To have a real multi-turn conversation, use the interactive client, which talks to `WS /v1/chat` like the mobile app (keeps the history, prints the answer as it streams in):

```bash
uv run python scripts/chat_repl.py                        # type your lines; /log shows the event log, /reset starts over, /quit exits
uv run python scripts/chat_repl.py --script rozmowa.txt   # replay a conversation, one utterance per line
```

With `event_log.enabled: true` in the config (copy a config and switch it on; it is off by default because the mobile app does not handle the event yet) the client sends `spoken_at` with every line, prints each recognised action under the answer and shows the whole event log at the end (`--log-wait` sets how many seconds of silence to wait for late entries). Recognition quality depends on the model, so check it with the model you use, e.g. a line like `Sprawdzam oddech, nie oddycha` should give `CHECK_BREATHING`.

### GPU

The GPU override only adds the NVIDIA device reservation to `llm` (and `asr`); pass both files:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

The flags apply to a single command. A later plain `docker compose up` recreates `llm` without the GPU, so to make it permanent put this in `.env` (the separator is `;` on Windows and `:` elsewhere):

```
COMPOSE_FILE=docker-compose.yml;docker-compose.gpu.yml
```

Check that Ollama uses it: `docker compose exec llm ollama ps` (column `PROCESSOR`). With a small GPU (e.g. 4 GB) a 7-8B model is split between GPU and CPU, and the share on the GPU decides the speed. The override therefore also sets `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0` (a quantised cache leaves room for more layers on the GPU), `OLLAMA_NUM_PARALLEL=1` (the server's calls queue instead of each taking longer and using more memory) and `OLLAMA_KEEP_ALIVE=30m` (loading a 7B model takes about a minute).

Without the GPU a 7B model can take longer than the 60 s call timeout of the LiteLLM adapter, and the answer fails. `/dev llm` (`scripts/dev.ps1 llm` at the repository root) always starts the container with the override.

### Changing the model

The model is set in the config, and the config is chosen with `APP_CONFIG`. Compose reads it from the shell or from `.env` in this directory:

```
APP_CONFIG=configs/experiments/qwen25-7b-compose.yaml
```

```bash
docker compose up -d --force-recreate app     # restart alone is not enough: the variable is fixed when the container is created
```

- Configs for the compose stack reach Ollama as `http://llm:11434` (`base.yaml`, `configs/experiments/*-compose.yaml`). `gemma.yaml` and `bielik.yaml` use `localhost` and are meant for an app started on the host.
- `llm-pull` downloads the Ollama model the config names before `app` starts (a model that is already in the `ollama_models` volume is not downloaded again). To pull one by hand: `docker compose exec llm ollama pull <name>`.
- A model built from a Modelfile (Bielik 7B v0.1) is not in the Ollama registry and needs a different start command, see "Models built from a Modelfile" below.
- Changes under `app/` need `--build`; prompts and configs are mounted, so editing them only needs a restart of `app`.
- Check what is running: `docker compose exec app printenv APP_CONFIG` and `docker compose exec llm ollama ps`.

### Models built from a Modelfile

Some GGUF files from Hugging Face (`hf.co/...`) get a wrong chat template from Ollama and answer with empty text or nonsense. The fix is a Modelfile in `configs/modelfiles/` that sets the right `TEMPLATE`; `ollama create` then builds a **local** model from it. Today this is Bielik 7B v0.1 (`configs/modelfiles/bielik-7b-v0.1.Modelfile`, model `bielik-7b-v01`, config `configs/experiments/bielik-7b-compose.yaml`). Models from the Ollama library (Qwen, Gemma, Bielik 11B, ...) do not need this.

Because such a model exists only in your local Ollama, it cannot be pulled from the registry. `llm-pull` would fail and `app` would never start, so **do not use plain `docker compose up`**. Instead:

```bash
# 1. start Ollama (add -f docker-compose.gpu.yml for the GPU, see above)
docker compose up -d llm

# 2. once: pull the GGUF and build the local model (the exact commands are at the top of the Modelfile)
docker compose exec llm ollama pull hf.co/speakleash/Bielik-7B-Instruct-v0.1-GGUF:Q4_K_M
docker compose cp configs/modelfiles/bielik-7b-v0.1.Modelfile llm:/root/Modelfile
docker compose exec llm ollama create bielik-7b-v01 -f /root/Modelfile

# 3. start the app without the pull step (--no-deps skips `llm-pull`)
APP_CONFIG=configs/experiments/bielik-7b-compose.yaml docker compose up -d --no-deps --force-recreate app
```

Step 2 is needed only once per Ollama volume (the model stays in `ollama_models`). From then on only step 3 is needed. With a GPU use `-f docker-compose.yml -f docker-compose.gpu.yml` in steps 1 and 3 (or `COMPOSE_FILE` in `.env`). When adding another model of this kind: first check whether it really needs a Modelfile (empty or wrong answers, `ollama show <model> --template`), then add the Modelfile and a config next to the existing ones.

A model change also needs a config in `configs/experiments/` and an entry in the evaluation results (`eval/results/`).

## Checks

```bash
uv sync
uv run pytest
uv run ruff check . && uv run ruff format --check .
uv run mypy app
```

Health: `curl localhost:8000/health`, `curl localhost:8000/v1/providers`.

## Configuration

Model setup lives in `configs/base.yaml` (pick another file with `APP_CONFIG`); secrets live in `.env`. Experiments go in `configs/experiments/`. The system prompt is `prompts/system_v1.md`.

## Mobile client

The demo mobile app lives in [`../mobile`](../mobile); it connects to `ws://<address>/v1/chat` (the address is set in the app's settings). From an Android emulator use `http://10.0.2.2:8000`; from a physical phone use the computer's LAN address and start the server with `--host 0.0.0.0` (`docker compose` already publishes the port).

To try reading aloud and interrupting without a model:

```powershell
$env:APP_CONFIG = "configs/fake.yaml"; uv run uvicorn app.main:app --host 0.0.0.0
```

Working rules for code and agents: [AGENTS.md](AGENTS.md) (and the project-wide [AGENTS.md](../../AGENTS.md)).
