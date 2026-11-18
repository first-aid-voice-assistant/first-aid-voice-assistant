from pathlib import Path

import yaml
from pydantic import BaseModel


class InterjectionPhrases(BaseModel):
    """Fixed reactions of the verbatim mode; `{last}` is the last instruction of the step."""

    fear: str
    question: str
    news: str
    other: str


class SpokenPhrases(BaseModel):
    """Fixed texts said in the verbatim mode, where the model never writes the answer."""

    idle: str
    stuck: str
    interject: InterjectionPhrases


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
    route_event: str
    route_intent: str
    route_interject: str
    spoken: SpokenPhrases


def load_scenario_prompts(path: str | Path) -> ScenarioPrompts:
    with open(path, encoding="utf-8") as f:
        return ScenarioPrompts.model_validate(yaml.safe_load(f))
