"""Entry of the event log: one rescue action reported by the user.

The format is defined in `docs/project/architecture.md` ("Event log entry") and shared with the
mobile app and the reference logs in `eval/`. The server only builds entries; the phone keeps
the log.
"""

from typing import Literal

from pydantic import AwareDatetime, BaseModel, Field


class EventLogEntry(BaseModel):
    id: str = Field(min_length=1, max_length=64)
    # End of the utterance in which the action was reported. A time zone is required, so that
    # the entry can never be read in the wrong one.
    timestamp: AwareDatetime
    # Seconds since the first entry of the log (the start of the rescue).
    elapsed_s: float = Field(ge=0)
    # Code from the action dictionary (`knowledge/scenarios/actions.yaml`).
    action: str = Field(pattern=r"^[A-Z][A-Z0-9_]*$")
    # What the user said; it also carries details the code does not, e.g. "10 breaths".
    transcript: str = Field(min_length=1, max_length=2000)
    # The LLM gives no confidence, so it is unset unless a provider reports one.
    confidence: float | None = Field(default=None, ge=0, le=1)
    source: Literal["local", "cloud"] | None = None
