"""Models of the knowledge base (`knowledge/` at the repository root).

The YAML files are the single source of truth; these models validate their shape. References
between files (sources, actions, steps) are checked by `loader.load_knowledge`.
"""

from datetime import date
from typing import Annotated, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

Level = Literal["layperson", "paramedic"]
MediaKey = Annotated[str, Field(pattern=r"^[a-z0-9-]+/[a-z0-9-]+$")]


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


class Instruction(BaseModel):
    text: str
    media: MediaKey | None = None


class Step(BaseModel):
    id: str
    instructions: list[Instruction] = Field(min_length=1)  # given one at a time
    asks: str | None = None
    media: MediaKey | None = None
    actions: list[str] = Field(default_factory=list)  # codes the rescuer may perform here
    transitions: list[Transition] = Field(default_factory=list)  # none = end of the scenario
    sources: list[SourceRef] = Field(default_factory=list)  # checked against sources/ if present
    note: str | None = None  # where the step goes beyond the guideline; for reviewers

    @field_validator("instructions", mode="before")
    @classmethod
    def _plain_strings_are_instructions(cls, value: object) -> object:
        if isinstance(value, list):
            return [{"text": item} if isinstance(item, str) else item for item in value]
        return value

    @property
    def units(self) -> list[str]:
        """What the assistant says in this step, one item per turn: instructions, then the ask."""
        return [*(i.text for i in self.instructions), *([self.asks] if self.asks else [])]

    @property
    def unit_media(self) -> list[str | None]:
        """The picture of every unit (see `units`)."""
        pictures = [i.media or self.media for i in self.instructions]
        return [*pictures, *([pictures[-1]] if self.asks else [])]


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
