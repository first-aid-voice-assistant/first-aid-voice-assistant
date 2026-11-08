"""Models of the knowledge base (`knowledge/` at the repository root).

The YAML files are the single source of truth; these models validate their shape. References
between files (sources, actions, steps) are checked by `loader.load_knowledge`.
"""

from datetime import date
from typing import Literal

from pydantic import BaseModel, Field, model_validator

Level = Literal["layperson", "paramedic"]


class Source(BaseModel):
    id: str
    title: str
    publisher: str
    version: str
    published: date | str | None = None
    reference: str | None = None
    urls: list[str] = Field(min_length=1)
    accessed: date
    scope: list[Level] = Field(default_factory=list)
    raw: list[str] = Field(default_factory=list)
    sections: list[str] = Field(min_length=1)
    notes: str | None = None


class Action(BaseModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9_]*$")
    name: str
    level: Level
    synonyms: list[str] = Field(default_factory=list)


class ActionDictionary(BaseModel):
    actions: list[Action]


class SourceRef(BaseModel):
    source: str
    section: str


class Transition(BaseModel):
    """Where the scenario goes when the condition holds: another step or another scenario."""

    when: str
    goto: str | None = None
    handoff: str | None = Field(default=None, pattern=r"^[\w-]+/[\w-]+$")  # scenario/step
    # A branch for an obstacle (e.g. no phone signal) that may be taken in the middle of a step,
    # before all its instructions were said. Other transitions wait until the step is done.
    interrupt: bool = False

    @model_validator(mode="after")
    def _exactly_one_target(self) -> "Transition":
        if (self.goto is None) == (self.handoff is None):
            raise ValueError("a transition needs exactly one of `goto` and `handoff`")
        return self


class Step(BaseModel):
    id: str
    instructions: list[str] = Field(min_length=1)  # given one at a time
    asks: str | None = None
    actions: list[str] = Field(default_factory=list)  # codes the rescuer may perform here
    transitions: list[Transition] = Field(default_factory=list)  # none = end of the scenario
    sources: list[SourceRef] = Field(default_factory=list)  # checked against sources/ if present
    note: str | None = None  # where the step goes beyond the guideline; for reviewers

    @property
    def units(self) -> list[str]:
        """What the assistant says in this step, one item per turn: instructions, then the ask."""
        return [*self.instructions, *([self.asks] if self.asks else [])]


class Scenario(BaseModel):
    id: str
    title: str
    trigger: str  # when the assistant should choose this scenario
    level: Level
    start: str
    steps: list[Step] = Field(min_length=1)

    def step(self, step_id: str) -> Step:
        return next(s for s in self.steps if s.id == step_id)


class KnowledgeBase(BaseModel):
    sources: list[Source]
    actions: list[Action]
    scenarios: list[Scenario]
