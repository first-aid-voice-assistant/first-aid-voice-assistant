# Event log: how to decide what is logged (2026-11-18)

Comparison behind [ADR 0003](../../docs/adr/0003-event-log-from-scenarios.md). A small check of the idea, not a statistically sound evaluation: the data are three scripted dialogues without speech-recognition noise and one model.

## Configuration

| | |
|---|---|
| Model | Qwen2.5 7B Instruct Q4_K_M (Ollama), temperature 0 for the side calls |
| Server | `configs/experiments/qwen25-7b-verbatim-eventlog-compose.yaml` (verbatim mode, event log on) |
| Scenarios | `knowledge/scenarios/` of this commit (adult BLS, choking, severe bleeding) |
| Prompts | `prompts/scenario_v1.yaml` (`route_intent`, `route_event`, `announcement`); the old call was `prompts/event_log_v1.yaml` (removed) |
| Dialogues | `poc/server/scripts/dialogues/adult-bls.txt` (39 utterances), `adult-choking.txt` (22), `adult-severe-bleeding.txt` (17) |

## Data and annotation

Each utterance of the three scripts was annotated by hand with the actions it reports as done or being done ("required") and the actions that are acceptable but not required, e.g. a continuing action ("acceptable"). 22 required actions in total. Entries for observations (a new kind, not in the old dictionary) are not scored here. A second set has 25 replies in which nothing was done ("Nie mam opaski", "Boję się", "Zaraz to zrobię", "Co mam powiedzieć?"…), each shown after the instruction it answers.

## Results

| Approach | Required actions missed (of 22) | Entries the user did not report | Extra model call |
|---|---|---|---|
| (a) ADR 0002: the model chooses from the whole dictionary (22 options) | 11 | 44 | yes (1–3 s) |
| (c) the same call, only the actions of the current step | 5 | 3 | yes (about 0.5–1 s) |
| (b) the scenario rule: the instruction names its action, the user's confirmation logs it | 1 | 0 | no |
| (b) in the running server (this commit) | 1 | 0 | no |

On the 25 replies where nothing was done: (a) 3 false entries, (c) 3, rule 3 (all announcements: "Zaraz to zrobię", "Zaraz sprawdzę", "Zaraz zadzwonię"), rule with the announcement pattern 0. Accepting also the replies the intent call labels as other (without a question mark, refusal or announcement) found all 22 but gave 1 wrong entry in the dialogues and 1 among the 25 (not adopted).

The one miss of the rule: "Założyłem opaskę nad raną, kilka centymetrów powyżej" was labelled as something other than a confirmation, so the tourniquet application was not logged (writing its time was).

Latency of a turn (verbatim mode, single local model): about 1.6 s without any event log, 4.9–5.9 s with the old call, about 2.2 s per turn with the scenario-driven log in the running server (the first run after a restart is slower because the model loads). The rule adds no call; the intent call it relies on is made by the dialogue anyway (about 1.1 s).

Examples of what the old call wrote that the user never said: "Rozumiem" → tourniquet applied and its time written; "Włączyłem głośnik" → chest compressions started; "Kolega przestał reagować" → call for help and direct pressure.

## Not covered

Real speech recognition output, other models, several actions in one sentence and actions reported out of order (the rule logs only the confirmed one), the cancelled-turn case. To repeat on the recordings of `eval/datasets/` once they exist, with reference logs in the format of `docs/project/architecture.md`.
