from pathlib import Path

import yaml
from pydantic import BaseModel


class EventLogPrompts(BaseModel):
    """Wording of the event log calls, from `prompts/event_log_v1.yaml`."""

    route_actions: str


def load_event_log_prompts(path: str | Path) -> EventLogPrompts:
    with open(path, encoding="utf-8") as f:
        return EventLogPrompts.model_validate(yaml.safe_load(f))
