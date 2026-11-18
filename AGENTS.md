# First-aid voice assistant – project-wide rules

These rules apply to the whole repository, for people and coding agents alike. Each part has its own `AGENTS.md` with the rules specific to it:

- `poc/server/AGENTS.md` – test server (Python, FastAPI)
- `poc/mobile/AGENTS.md` – demo mobile app (Flutter)

Read the `AGENTS.md` of the part you are changing before you start.

## Project

A voice assistant for emergencies and first aid. It listens to the person giving help (a paramedic or a layperson), recognises the rescue actions they perform, records them with timestamps in an event log and prompts the next steps according to prepared scenarios. It is a master's thesis project and a research prototype, not a medical device.

Overview, requirements and architecture: `docs/project/`.

## Domain and safety

- The assistant must never be the only way to get help: every client shows a "call 112" fallback when the backend is unreachable or returns an error.
- **Emergency numbers (decided 2026-11-15, for Poland):** when an ambulance is needed, scenarios and prompts send the user to **999** (it reaches a medical dispatcher directly), spoken as "dziewięćset dziewięćdziesiąt dziewięć". **112** (the general emergency number) stays (a) where the danger may also need the fire brigade or police (e.g. an unsafe scene), (b) where we do not know whom to call (no procedure matches: the assistant stays calm and sends the user to 112) and (c) as the fallback in every client (the always-visible call button, the backend-error message). Do not replace the fallback with 999.
- Safety rules live in the system prompts (call for help first – 999 when an ambulance is needed, otherwise 112 – rescuer safety first, no diagnoses, no drug dosing, never invent procedures, one short instruction at a time). Do not weaken or remove them; any prompt change must be re-checked against them and, ideally, reviewed by a medical professional.
- The assistant suggests only steps that exist in the knowledge base (`knowledge/`). Medical facts must come from vetted sources, not from the model's memory.
- The model must not simply agree with the user: it checks what the user says against the scenario and corrects it when needed.
- **Answers outside the scenarios (decided 2026-11-15):** when a question, worry or problem goes outside the scenario, the assistant always answers in the same style: it ends every such answer by repeating the last instruction ("let's focus on this", "calm down, try ..."), and before that, depending on what was said: for fear it reassures the person; for a question outside the scenario it says that the dispatcher will explain it; for something new about the person in need (e.g. vomiting, seizure) it tells the caller to tell the dispatcher right away. It never dismisses what was said as unimportant. It adds no medical advice of its own and invents no procedure; when no scenario fits, it calmly sends the person to 112. Failing loudly still applies to system errors: they surface as an explicit error response with the "call 112" fallback.

## Repository layout

- `docs/` – project documentation (`project/`, `adr/`)
- `poc/` – proof of concept: `server/`, `mobile/`
- `apps/` – target application (not started)
- `knowledge/` – knowledge base shared by all parts
- `eval/` – evaluation datasets, scripts and results

## Rules

- **Language:** everything is in English – code, comments, commit messages, pull requests and all documentation (`README.md`, `AGENTS.md`, `CLAUDE.md`, every `docs/` folder). Only end-user-facing content (system prompts, domain glossaries) may be in Polish.
- **Secrets** live only in `.env` files, never in code or configs; each part keeps a `.env.example`.
- **Data:** evaluation recordings and raw source documents are not committed (`eval/datasets/`, `knowledge/raw/` are git-ignored) – they may contain personal data or be under licences that forbid redistribution.
- **API:** the API used by the mobile app is defined by the server's Pydantic models (browse it at `/docs` of the running server). A change to it updates the mobile app in the same pull request. The event-log entry format, shared with the evaluation, is described in `docs/project/architecture.md`.
- **Documentation:** documents in `docs/` folders carry the metadata header and revision history described in `CONTRIBUTING.md`. Update the docs of the part you change in the same pull request.
- Git workflow (branches, commits, pull requests): `CONTRIBUTING.md`.

## Skills

Project-wide skills live in `.claude/skills/`; skills of a single part live in that part's `.claude/skills/` (e.g. `poc/server/.claude/skills/`).

- `pr-description` – writes a pull request title and a short bullet list of changes for a branch, in the team's style.
