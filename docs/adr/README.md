# Architecture decision records

One short file per decision that affects the architecture or the technology stack, named `NNNN-short-title.md` (e.g. `0001-flutter-for-mobile-app.md`). Decisions are not edited after acceptance; a changed decision gets a new record that supersedes the old one.

## Records

| No. | Decision | Status |
|---|---|---|
| [0001](0001-flutter-for-mobile-app.md) | Flutter for the mobile app | accepted |
| [0002](0002-event-log-detection.md) | Event log: the server recognises actions, the phone keeps the log | accepted |

## Template

```markdown
# NNNN. Title

| | |
|---|---|
| **Created** | YYYY-MM-DD |
| **Status** | proposed / accepted / superseded by NNNN |

## Context

What problem we face and what constraints apply.

## Decision

What we decided.

## Alternatives considered

Other options and why they were rejected.

## Consequences

What becomes easier or harder because of this decision.
```
