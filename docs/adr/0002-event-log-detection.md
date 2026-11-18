# 0002. Event log: the server recognises actions, the phone keeps the log

| | |
|---|---|
| **Created** | 2026-11-08 |
| **Status** | accepted |

## Context

The assistant has to record the rescue actions the user performs, in order and with timestamps (e.g. `10:15:32 – check of breathing, the casualty is not breathing`, `10:16:22 – chest compressions started`), instead of a raw transcript of the conversation. The entry format is defined in `docs/project/architecture.md` ("Event log entry") and shared with the evaluation.

Constraints:

- The architecture keeps the action state on the phone and the server holds no sessions (`docs/project/architecture.md`, "Key decisions"). The log must keep working without the server in the later offline version (FR-9, NFR-4).
- Timestamps are the end of the utterance, so server latency does not distort the log (FR-3).
- In the PoC the language model runs on the server, in the target version it may run on the phone.
- The team is small. Two implementations of the same logic (server and app) would have to be kept in sync, and the offline version has to exist next to the online one.

## Decision

**In the PoC the server recognises the actions and the phone stores them.**

1. The app sends the question as before, plus `spoken_at`: the moment the user finished speaking (ISO 8601 with a time zone). Without it the server uses the time it received the question.
2. In parallel with the answer, the server makes one short side call to the model (temperature 0). The call gets the user's words, the assistant's last message and the numbered action dictionary (`knowledge/scenarios/actions.yaml`), and returns the numbers of the actions the user reports as done or being done, or `0`. The wording is in `prompts/event_log_v1.yaml`.
3. A reply that is not a clean list of valid numbers means "no action": a missing entry is better than an invented one. An action repeated right after itself ("I am pressing", "still pressing") is logged once; it can be logged again after another action.
4. For every recognised action the server sends an `action_logged` event with an entry in the shared format (`transcript` is the user's words and carries details the code does not, such as "10 breaths"). Failure of this call is only logged on the server: it does not stop the answer and does not trigger the client's "call 112" fallback, which is reserved for the answer failing. It is switched on by `event_log.enabled` in the server config, because a client that does not know the event would fail on it.
5. The server keeps no log. Its only state is the last logged action (for point 3) and the time of the first entry (for `elapsed_s`), per WebSocket connection.

**How the mobile app handles it** (planned, `poc/mobile` is not updated yet): the protocol parser accepts `action_logged` (an unknown event type must never break the connection) and the app sends `spoken_at` with every question. The repository passes the entry on to the conversation view model, which appends it to the event log; in the PoC the log is kept in memory, the target is a local database with export (FR-8). The log belongs to the phone, so it works the same when the server is gone.

**Direction beyond the PoC.** Most of the server logic (walking through scenarios, recognising actions, building prompts, recording the log) is meant to move to Dart in the mobile app, so that the fully offline version and the online version share one implementation instead of two. The PoC server is then the reference implementation and a place to measure quality (`eval/`), not the final home of this logic. What stays shared is the contract: the entry format, the action dictionary and scenarios in `knowledge/`, and the prompt files. The server code is written to be ported: the parsing and the recorder are plain functions and classes with no dependency on FastAPI or LiteLLM, and the unit tests are the specification for the Dart tests.

## Alternatives considered

- **Recognition on the phone right away** – matches the target version, but the PoC has no model on the device; it would also delay measuring the quality of recognition with the models we already run.
- **A log stored on the server** (memory, Redis, a file; fetched over REST) – simple to try, but it contradicts the offline direction, needs session ids and authentication, and would be thrown away when the logic moves to the phone.
- **Deriving entries from the scenario cursor** (an entry whenever the dialogue passes a step bound to an action) – deterministic and needs no extra call, but it does not catch actions reported out of order or outside the current step, and it records what the assistant asked for rather than what the user said they did.
- **Recognition inside the answer call** (the model writes the answer and the actions together) – saves one call, but a small model then has to follow two tasks at once, the answer would have to be parsed, and an interrupted answer would lose the entry.

## Consequences

- The log needs no server sessions and keeps working offline once recognition runs on the phone. The server must stay compatible with a phone that sends `spoken_at` or does not.
- Every utterance costs one more model call, in parallel with the answer. On a single local model the two calls may queue and slow the answer down; this has to be measured.
- Recognition covers only actions that exist in the action dictionary, and small models may stick too closely to its example phrases. Quality is measured against the reference logs in `eval/`; narrowing the candidates to the actions of the current step (`Step.actions`) is the next lever.
- After a reconnect the server forgets the last action, so the first entry of a continuing action may be repeated. Acceptable in the PoC.
- A client that does not know `action_logged` must run with `event_log.enabled: false` until it is updated.
- Changes to the prompt, the dictionary or the entry format must be kept in step with the phone and `eval/`, and later with the Dart port.
