from collections.abc import AsyncIterator
from pathlib import Path

import pytest

from app.eventlog.detector import ActionDetector, parse_choices
from app.eventlog.prompts import load_event_log_prompts
from app.knowledge import load_knowledge
from app.providers.base import LLMDelta, LLMDone, LLMEvent, LLMOptions, Message

KNOWLEDGE = Path("../../knowledge")
EVENT_LOG_PROMPTS = Path("prompts/event_log_v1.yaml")


class ScriptedLLM:
    """Answers every call with one reply and keeps the prompts it got."""

    name = "scripted"

    def __init__(self, reply: str) -> None:
        self.reply = reply
        self.prompts: list[str] = []

    async def generate_stream(
        self, messages: list[Message], opts: LLMOptions
    ) -> AsyncIterator[LLMEvent]:
        self.prompts.append(messages[-1].content)
        yield LLMDelta(text=self.reply)
        yield LLMDone(text=self.reply)


def make(reply: str) -> tuple[ActionDetector, ScriptedLLM]:
    llm = ScriptedLLM(reply)
    actions = load_knowledge(KNOWLEDGE).actions
    return ActionDetector(llm, actions, load_event_log_prompts(EVENT_LOG_PROMPTS)), llm


@pytest.mark.parametrize(
    ("reply", "expected"),
    [
        ("3", [3]),
        ("2, 5", [2, 5]),
        ("5, 5, 2", [5, 2]),  # repeats dropped
        ("0", []),
        ("0, 3", []),  # "none" first: the reply contradicts itself
        ("99", []),  # no such action
        ("Myślę, że 3", []),  # words around the digits: not trusted
        ("", []),
    ],
)
def test_parse_choices_accepts_only_a_clean_list_of_valid_numbers(
    reply: str, expected: list[int]
) -> None:
    assert parse_choices(reply, options=13) == expected


async def test_detect_maps_the_numbers_to_action_codes() -> None:
    detector, _ = make("5, 7")

    codes = await detector.detect("Sprawdzam oddech, nie oddycha. Zaczynam uciskać.", [])

    assert codes == ["CHECK_BREATHING", "CHEST_COMPRESSIONS"]


async def test_detect_gives_nothing_when_the_model_says_none() -> None:
    detector, _ = make("0")

    assert await detector.detect("Zaraz zadzwonię", []) == []


async def test_detect_shows_the_model_the_last_assistant_message_and_the_dictionary() -> None:
    detector, llm = make("0")
    history = [
        Message(role="user", content="Kolega leży"),
        Message(role="assistant", content="Zadzwoń na 112."),
    ]

    await detector.detect("Tak, zrobione", history)

    prompt = llm.prompts[0]
    assert "Zadzwoń na 112." in prompt  # lets "tak, zrobione" be tied to the instructed action
    assert "Wezwanie służb ratunkowych" in prompt
