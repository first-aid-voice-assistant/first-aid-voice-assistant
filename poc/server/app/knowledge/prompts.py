from pathlib import Path

import yaml
from pydantic import BaseModel


class ScenarioPrompts(BaseModel):
    """Wording of the guided conversation, from `prompts/scenario_v1.yaml`."""

    rules: str
    say: str
    repeat: str
    idle: str
    finished: str
    interject: str
    stuck: str
    route_scenario: str
    route_step: str
    route_intent: str


def load_scenario_prompts(path: str | Path) -> ScenarioPrompts:
    with open(path, encoding="utf-8") as f:
        return ScenarioPrompts.model_validate(yaml.safe_load(f))
