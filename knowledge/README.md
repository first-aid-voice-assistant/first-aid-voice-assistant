# Knowledge base

Vetted first-aid and emergency-medicine knowledge that the assistant relies on. Shared by the PoC and the target application. The assistant suggests only steps that exist here.

| Path | Content | In git |
|---|---|---|
| `scenarios/` | Machine-readable rules in YAML: `actions.yaml` (dictionary of rescue actions) and one file per scenario | yes |
| `sources/` | Optional descriptions of the source documents, one YAML file per document (see below) | yes, when added |
| `raw/` | Original documents (guidelines, procedures, training materials) | **no** – may be under licences that forbid redistribution |

## Principles

- Scenarios are state machines: steps, transition conditions (e.g. "is the person breathing?") and separate content for laypeople and paramedics. Timers (e.g. changing the person doing compressions) are planned.
- The action dictionary gives every action a code, a name, a level (layperson / paramedic) and colloquial synonyms (e.g. "uciskam", "masaż serca", "RKO"). The same codes are used in the event log and in the reference logs in `eval/`.
- Steps should refer to the source (document and section) they come from.
- Rules should be reviewed by a medical professional before they are used in an evaluation.

## Scenarios

| File | Content |
|---|---|
| `actions.yaml` | Actions: `code` (e.g. `CHEST_COMPRESSIONS`), Polish `name`, `level`, colloquial `synonyms` |
| `adult-bls.yaml` | Adult cardiac arrest: check safety and response, call 999, check breathing, compressions, rescue breaths 30:2 for trained rescuers, AED; hands an unresponsive person who breathes normally to the recovery position |
| `adult-choking.yaml` | Adult choking: cough, 5 back blows, 5 abdominal thrusts, alternating, CPR when the person becomes unresponsive |
| `adult-recovery-position.yaml` | Unresponsive adult who breathes normally: exclusion of trauma, recovery position step by step, monitoring of breathing |
| `adult-severe-bleeding.yaml` | Life-threatening external bleeding: call 999, direct pressure, dressing, pressure dressing, tourniquet for limbs when pressure fails |

A scenario has `id`, `title`, `trigger` (when to choose it), `level`, `start` and a list of `steps`. A step has:

- `instructions` – what to say, one at a time (Polish, numbers in words because the answer is read aloud); an item is a string, or `{text, media}` when it has its own picture;
- `media` – optional name of the picture the mobile app shows while the step's instructions are said (`<set>/<picture>`, e.g. `cpr/compressions`); an instruction's own `media` wins, the question in `asks` keeps the picture of the last instruction. A scenario that uses pictures must have one for every instruction. The drawings live in the app (`poc/mobile/assets/illustrations/`) and need the same medical review as the text;
- `asks` – an optional question asked after the instructions;
- `actions` – codes from `actions.yaml` the rescuer may perform in this step;
- `transitions` – `when` (a condition, in Polish) and `goto` (a step) or `handoff` (`scenario/step`); an optional `interrupt: true` marks a branch for an obstacle (e.g. no phone signal) that may be taken in the middle of a step, before all its instructions were said; other transitions wait until the step is done; a step without transitions ends the scenario;
- `sources` – optional citations, see below;
- `note` – where the step goes beyond the guideline, for reviewers. A note that needs a medical reviewer's decision starts with `NEEDS MEDICAL REVIEW:` (the same marker opens the comments at the top of a file); list them all with `grep -rn "NEEDS MEDICAL REVIEW" knowledge/scenarios`.

The server (`poc/server/app/knowledge/`) validates the files at start-up and refuses to start when a transition, action or (if source files are present) citation does not exist, a step is unreachable, or a scenario with pictures has an instruction without one. It walks through a scenario one instruction at a time and shows the model only the current one.

## Sources

A source file has `id`, `title`, `publisher`, `version`, `published`, `urls`, `accessed` (access date), `scope` (layperson / paramedic), `raw` (file names in `raw/`), `sections` (the sections that steps may cite) and optional `notes`. A step cites a source with `source` (the `id`) and `section` (listed in the source; it may continue with ` – <detail>`). The citations are checked only when `sources/` has files.

## Status

Four draft scenarios (adult BLS with AED, adult choking, recovery position, severe bleeding) based **only** on the ERC Guidelines 2025 (Adult Basic Life Support and First Aid, described in `sources/`; the PDFs are in `raw/`). The citations are validated against `sources/`. **Not yet reviewed by a medical professional**; the points to check are in the `note` fields and in the comments at the top of the files, in particular: choking calls the ambulance (999) after the first round, as the ERC does (the project rule is to call first, so anyone nearby is asked to call at once); the tourniquet is offered only to a caller who has a manufactured one and knows how to use it; what a lone rescuer does with the AED and with no phone signal is an inference. The pictures of `adult-bls` come from an earlier set; `cpr/aed` has no drawing in the app yet. Out of scope for now: children, other first-aid topics of the ERC First Aid guideline (e.g. open chest wounds, amputated body part).
