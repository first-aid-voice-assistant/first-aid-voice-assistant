# 0003. Event log: the scenarios decide what is logged, no model call

| | |
|---|---|
| **Created** | 2026-11-18 |
| **Status** | accepted |

Supersedes points 2 and 3 of [0002](0002-event-log-detection.md) (a side call to the model recognises the actions). The rest of 0002 stays: the server sends entries, the phone keeps the log, `spoken_at` stamps them, `action_logged` carries them, a failure of the log never triggers the "call 112" fallback.

## Context

ADR 0002 had the server ask the model, for every utterance, which actions of the whole dictionary (22 options) the user had reported. We measured that on the staged dialogues in `poc/server/scripts/dialogues/` (adult BLS, choking, severe bleeding; Qwen2.5 7B, 22 actions that the user really reported, annotated by hand):

- It found 11 of the 22 and wrote **44 entries the user never reported**. Examples: "Rozumiem" gave "tourniquet applied" and "time written down"; "Włączyłem głośnik" gave "chest compressions"; "Kolega przestał reagować" gave "call for help" and "direct pressure". It missed "Uciskam i liczę" (the start of CPR), "Dzwonię" and "Zapisałem godzinę na opasce".
- The extra call made a turn about three times slower on a single local model (1.6 s without it, 4.9–5.9 s with it).
- People who take over need the facts they cannot see: how long a tourniquet has been on, how long CPR has been going on, when the person stopped responding, when the AED came. A wrong entry there is worse than a missing one, and "stopped responding" is not an action, so the dictionary could not hold it.

The dialogue already knows which instruction it has just said and already classifies the user's reply (confirmation, problem, other) and which branch the scenario takes.

## Decision

**The scenarios say what is logged; the model is not asked.**

1. An instruction may name the action it asks for (`action` in `knowledge/scenarios/`). When the user confirms that instruction, the action is logged. "Confirms" is the intent the dialogue computes anyway (`POTWIERDZENIE`). Not logged: a question or a problem, an answer to an `asks`, a reply that only announces the action ("zaraz zadzwonię"; a pattern in `prompts/scenario_v1.yaml`), and a reply that reports an event (an `interrupt` branch) instead of confirming.
2. A transition may name an observation (`log`), logged when the branch is taken because of what the user said. The dictionary marks codes as `kind: action` or `kind: observation`. New observations: `UNRESPONSIVE`, `BREATHING_ABNORMAL`, `AED_ARRIVED`, `CPR_STOPPED`, `OBSTRUCTION_CLEARED`, `BLEEDING_CONTROLLED`, `BLEEDING_RETURNED`.
3. The loader checks the references: an unknown code, an `action` that is not among the `actions` of its step, an observation used as an action, a `log` that is not an observation, and a `log` on `when: zawsze` stop the server from starting.
4. The recorder logs an action repeated right after itself once; observations are always logged and do not break that chain.
5. The detector, `prompts/event_log_v1.yaml` and `prompts.event_log` are removed. The entry format, `spoken_at`, `event_log.enabled` and the `action_logged` event do not change.

## Evidence

The same recorded dialogues and annotation (small, scripted, no speech-recognition noise, 7B only; details in `eval/results/2026-11-18-event-log-detection.md`):

| Approach | Of 22 reported, missed | Entries not reported by the user | Extra model call |
|---|---|---|---|
| ADR 0002: whole dictionary | 11 | 44 | yes |
| The same call, only the actions of the current step | 5 | 3 | yes |
| **The scenario rule (this ADR)** | **1** | **0** | **no** |

On 25 replies in which nothing was done ("Nie mam opaski", "Boję się", "Zaraz to zrobię"…), the rule produced 3 false entries (all announcements), which the announcement pattern removes; the model approaches produced 3 each.

## Alternatives considered

- **Keep the model call** (ADR 0002). Rejected: the worst results on every measure and the slowest.
- **Narrow the model call to the actions of the current step** (the lever ADR 0002 itself named). Better than the whole dictionary, but still a call and still invented entries.
- **Also accept a reply the intent call labels as "other" (without a question mark, refusal or announcement) as a confirmation.** In the test it found all 22 actions, at the price of one wrong entry in the dialogues and one among the 25 negatives; not taken for now, because a missing entry is safer than an invented one. It can be reconsidered when real recordings are available.
- **A model call only for what the scenario did not ask for** (out-of-order reports, several actions in one sentence). Not built; it can be added later and measured against the rule.

## Consequences

- No extra latency and no invented entries from the log; the log is deterministic, reviewable together with the scenarios (the medical review covers what is logged) and easy to port to Dart (a regular expression, the dialogue state and the dictionary).
- The log reflects what the scenario asked and the user answered. An action reported out of order, or two actions in one sentence, give only the confirmed one.
- The quality now rests on the intent classification: one tourniquet confirmation in the test was classified as something else and not logged. It must be measured on real recordings in `eval/`.
- Observations make the log useful for the people who take over (when the person stopped responding, when the AED arrived, when CPR ended), but they are as reliable as the transition the dialogue chose.
- If the user speaks again while the dialogue is still classifying the previous words, that turn is cancelled and its entry can be lost.
- Every instruction that asks for a rescue action needs its `action` in the scenario; a new scenario without them logs nothing.
