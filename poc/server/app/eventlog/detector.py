"""Recognises which rescue actions the user reports in one utterance.

A short side call to the model picks numbers from the action dictionary. Anything that is not
a clean list of valid numbers is read as "no action": a missing entry is better than an
invented one. The parsing is plain string work, kept free of FastAPI and LiteLLM so that it can
be ported to the mobile app as it is.
"""

import re

from app.eventlog.prompts import EventLogPrompts
from app.knowledge.models import Action
from app.pipeline.completion import complete
from app.providers.base import LLMProvider, Message

_MAX_TOKENS = 24
_NUMBERS = re.compile(r"\W*\d+(?:\W+\d+)*\W*")  # the whole reply: digits and separators only


def _one_line(text: str) -> str:
    return " ".join(text.split())


def parse_choices(reply: str, options: int) -> list[int]:
    """Numbers (1..options) from a reply like "2, 5"; empty for "0" and for anything unclear."""
    if _NUMBERS.fullmatch(reply) is None:
        return []
    numbers = [int(n) for n in re.findall(r"\d+", reply)]
    if numbers[0] == 0 or any(n > options for n in numbers):
        return []  # "0 ..." is "none"; a number outside the list means the reply cannot be trusted
    return list(dict.fromkeys(numbers))  # no repeats, order kept


class ActionDetector:
    def __init__(self, llm: LLMProvider, actions: list[Action], prompts: EventLogPrompts) -> None:
        self._llm = llm
        self._actions = actions
        self._prompts = prompts
        self._options = "\n".join(
            f"{i}. {a.name}" + (f" (np. {', '.join(a.synonyms)})" if a.synonyms else "")
            for i, a in enumerate(actions, 1)
        )

    async def detect(self, user_text: str, history: list[Message]) -> list[str]:
        """Codes of the actions the user reported in `user_text`, as the model listed them."""
        last_assistant = next((m.content for m in reversed(history) if m.role == "assistant"), "")
        prompt = self._prompts.route_actions.format(
            assistant=_one_line(last_assistant) or "(brak)",
            user=_one_line(user_text),
            options=self._options,
        )
        reply = await complete(self._llm, prompt, _MAX_TOKENS)
        return [self._actions[n - 1].code for n in parse_choices(reply, len(self._actions))]
