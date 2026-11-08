"""Walks through a scenario one instruction at a time.

The model never sees a whole procedure, only the task of the current turn: say this one
instruction. Inside a step the cursor moves by itself (the user's next words are taken as
"done"); between steps a short side call to the model picks the transition that the user's
answer satisfies. When the call gives no clear answer the cursor stays where it is: the
assistant repeats instead of guessing.

The cursor moves only after an answer was completed, so an interrupted answer is said again.
The state lives as long as the object, i.e. one WebSocket connection.
"""

import re
from dataclasses import dataclass

from app.knowledge.models import KnowledgeBase, Scenario, Step, Transition
from app.knowledge.prompts import ScenarioPrompts
from app.pipeline.completion import complete
from app.providers.base import LLMProvider, Message

_USER_MESSAGES_FOR_ROUTING = 3
_DIGIT = re.compile(r"\W*(\d+)")
_OBSTACLE, _OTHER = "PRZESZKODA", "INNE"  # labels of the intent call
_INTENT_LABELS = ("POTWIERDZENIE", _OBSTACLE, _OTHER)
_REPEATS_BEFORE_ASKING = 2


def _one_line(text: str) -> str:
    return " ".join(text.split())


def with_task(system_prompt: str, task: str) -> str:
    return f"{system_prompt.rstrip()}\n\n{task}"


@dataclass
class KnowledgeRuntime:
    kb: KnowledgeBase
    prompts: ScenarioPrompts

    def system_prompt(self, base: str) -> str:
        return with_task(base, self.prompts.rules.strip())

    def dialogue(self, llm: LLMProvider) -> "ScenarioDialogue":
        return ScenarioDialogue(self.kb, self.prompts, llm)


class ScenarioDialogue:
    def __init__(self, kb: KnowledgeBase, prompts: ScenarioPrompts, llm: LLMProvider) -> None:
        self._scenarios = {s.id: s for s in kb.scenarios}
        self._prompts = prompts
        self._llm = llm
        self._scenario: Scenario | None = None
        self._step: Step | None = None
        self._unit = 0  # index of the next thing to say in the step (see Step.units)
        self._advance_on_completion = False
        self._moved = False  # the cursor entered a step during this turn
        self._repeats = 0  # consecutive turns in which the last instruction was repeated
        self._interjected = False  # the previous turn answered a problem instead of moving on

    async def begin_turn(self, user_text: str, history: list[Message]) -> str:
        """Moves the cursor if the user's words call for it; returns the task for the model."""
        self._advance_on_completion = False
        self._moved = False
        was_interjected, self._interjected = self._interjected, False
        interject = False
        if self._step is None:
            await self._choose_scenario(user_text, history)
        elif self._unit > 0 and (self._step.transitions or self._unit < len(self._step.units)):
            # Something was said in this step, so the user is reacting to it. A confirmation lets
            # the cursor go on; a problem may call for a transition (e.g. no phone signal); a
            # problem or a question outside the procedure is answered without moving on.
            intent = await self._intent(user_text, history)
            exhausted = self._unit >= len(self._step.units)
            if intent == _OTHER and "?" not in user_text:
                intent = ""  # a statement ("I am afraid") is not a question: the procedure goes on
            if intent == _OBSTACLE or (exhausted and intent != _OTHER):
                await self._follow_transition(user_text, history, interrupting=not exhausted)
            # A problem or a question outside the procedure is sent to the dispatcher only once in
            # a row; if the user keeps raising them, the procedure goes on.
            interject = not self._moved and intent in (_OBSTACLE, _OTHER) and not was_interjected

        if self._step is None:
            titles = ", ".join(s.title for s in self._scenarios.values())
            return self._prompts.idle.format(titles=titles).strip()
        units = self._step.units
        if interject:
            self._interjected = True
            return self._prompts.interject.format(
                last=units[min(self._unit, len(units)) - 1]
            ).strip()
        if self._unit < len(units):
            self._repeats = 0
            self._advance_on_completion = True
            return self._prompts.say.format(instruction=units[self._unit]).strip()
        if not self._step.transitions:
            return self._prompts.finished.strip()
        self._repeats += 1
        if self._repeats > _REPEATS_BEFORE_ASKING:
            return self._prompts.stuck.strip()
        return self._prompts.repeat.format(last=units[-1]).strip()

    def turn_completed(self) -> None:
        if self._advance_on_completion:
            self._unit += 1
        self._advance_on_completion = False

    async def _choose_scenario(self, user_text: str, history: list[Message]) -> None:
        scenarios = list(self._scenarios.values())
        user_messages = [m.content for m in history if m.role == "user"]
        recent = [*user_messages[-_USER_MESSAGES_FOR_ROUTING:], user_text]
        prompt = self._prompts.route_scenario.format(
            messages="\n".join(f"- {_one_line(t)}" for t in recent),
            options="\n".join(
                f"{i}. {s.title}: {_one_line(s.trigger)}" for i, s in enumerate(scenarios, 1)
            ),
        )
        choice = await self._choose(prompt, len(scenarios))
        if choice:
            self._enter(scenarios[choice - 1], scenarios[choice - 1].start)

    async def _intent(self, user_text: str, history: list[Message]) -> str:
        """The kind of the user's words: one of _INTENT_LABELS, or "" when the reply is unclear."""
        last_assistant = next((m.content for m in reversed(history) if m.role == "assistant"), "")
        prompt = self._prompts.route_intent.format(
            assistant=_one_line(last_assistant), user=_one_line(user_text)
        )
        text = await self._complete(prompt, max_tokens=8)
        word = re.match(r"\W*(\w+)", text)
        label = word.group(1).upper() if word else ""
        return label if label in _INTENT_LABELS else ""

    async def _follow_transition(
        self, user_text: str, history: list[Message], *, interrupting: bool = False
    ) -> None:
        assert self._step is not None
        transitions = [t for t in self._step.transitions if t.interrupt or not interrupting]
        if not transitions:
            return
        if interrupting and len(transitions) == 1:
            # The intent call already judged the words an obstacle and this is the only branch
            # for one: asking the model to pick a number again only adds noise.
            self._take(transitions[0])
            return
        last_assistant = next((m.content for m in reversed(history) if m.role == "assistant"), "")
        prompt = self._prompts.route_step.format(
            assistant=_one_line(last_assistant),
            user=_one_line(user_text),
            options="\n".join(f"{i}. {_one_line(t.when)}" for i, t in enumerate(transitions, 1)),
        )
        choice = await self._choose(prompt, len(transitions))
        if not choice:
            return
        self._take(transitions[choice - 1])

    def _take(self, chosen: Transition) -> None:
        if chosen.goto is not None:
            assert self._scenario is not None
            self._enter(self._scenario, chosen.goto)
        elif chosen.handoff is not None:
            scenario_id, _, step_id = chosen.handoff.partition("/")
            self._enter(self._scenarios[scenario_id], step_id)

    def _enter(self, scenario: Scenario, step_id: str) -> None:
        self._scenario = scenario
        self._step = scenario.step(step_id)
        self._unit = 0
        self._moved = True
        self._repeats = 0

    async def _complete(self, prompt: str, max_tokens: int) -> str:
        return await complete(self._llm, prompt, max_tokens)

    async def _choose(self, prompt: str, options: int) -> int:
        """Asks the model for one digit; 0 means "none" and is also the answer to anything else."""
        match = _DIGIT.match(await self._complete(prompt, max_tokens=8))
        if match is None:
            return 0
        value = int(match.group(1))
        return value if value <= options else 0
