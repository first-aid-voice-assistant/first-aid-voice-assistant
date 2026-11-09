from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from app.knowledge import (
    KnowledgeRuntime,
    ScenarioDialogue,
    load_knowledge,
    load_scenario_prompts,
)
from app.main import create_app
from app.providers.base import LLMDelta, LLMDone, LLMEvent, LLMOptions, Message

KNOWLEDGE = Path("../../knowledge")
SCENARIO_PROMPTS = Path("prompts/scenario_v1.yaml")
BLS, CHOKING = "1", "2"  # alphabetical order of the scenario files, as the router lists them


class ScriptedLLM:
    """Returns the given replies one by one and records every prompt it got."""

    name = "scripted"

    def __init__(self, replies: list[str], intents: list[str] | None = None) -> None:
        self.replies = list(replies)
        # Replies of the call that classifies the user's words (POTWIERDZENIE by default).
        self.intents = list(intents or [])
        self.calls: list[list[Message]] = []

    async def generate_stream(
        self, messages: list[Message], opts: LLMOptions
    ) -> AsyncIterator[LLMEvent]:
        if "Wybierz jedną etykietę" in messages[0].content:
            reply = self.intents.pop(0) if self.intents else "POTWIERDZENIE"
        else:
            self.calls.append(messages)
            reply = self.replies.pop(0) if self.replies else ""
        yield LLMDelta(text=reply)
        yield LLMDone(text=reply)


def make(
    replies: list[str], intents: list[str] | None = None
) -> tuple[ScenarioDialogue, ScriptedLLM]:
    runtime = KnowledgeRuntime(load_knowledge(KNOWLEDGE), load_scenario_prompts(SCENARIO_PROMPTS))
    llm = ScriptedLLM(replies, intents)
    return runtime.dialogue(llm), llm


async def turn(dialogue: ScenarioDialogue, text: str = "ok") -> str:
    task = await dialogue.begin_turn(text, [])
    dialogue.turn_completed()
    return task


async def test_first_turn_picks_the_scenario_and_gives_only_its_first_instruction() -> None:
    dialogue, llm = make([BLS])

    task = await dialogue.begin_turn("Kolega leży i się nie rusza", [])

    assert "Ty, poszkodowany i świadkowie" in task
    assert "potrząśnij" not in task
    assert len(llm.calls) == 1  # only the call that chose the scenario


async def test_no_matching_scenario_gives_no_instructions_and_asks_again_next_turn() -> None:
    dialogue, _ = make(["0", CHOKING])

    first = await turn(dialogue, "Boli mnie głowa")
    second = await turn(dialogue, "Tata się dławi")

    assert "nie wybrano jeszcze procedury" in first
    assert "Zadławienie osoby dorosłej" in first  # the model is told what it knows
    assert "Zapytaj poszkodowanego, czy się dławi" in second


async def test_instructions_inside_a_step_come_one_per_turn_without_calling_the_model() -> None:
    # call_emergency has two instructions. Safety and response check are one each.
    dialogue, llm = make([BLS, "1", "1"])
    await turn(dialogue, "Nie rusza się")  # safety
    await turn(dialogue, "Jest bezpiecznie")  # check_response
    first = await turn(dialogue, "Nie reaguje")  # call_emergency, instruction 1
    calls_so_far = len(llm.calls)

    second = await turn(dialogue)

    assert "poproś, żeby zadzwonił pod sto dwanaście" in first
    assert "tryb głośnomówiący" in second
    assert "zostań z poszkodowanym" in second  # the last two gestures are one instruction
    assert len(llm.calls) == calls_so_far


async def test_the_cursor_waits_when_the_answer_matches_no_condition() -> None:
    dialogue, _ = make([BLS, "0", "1"])
    await turn(dialogue, "Nie rusza się")  # safety, its only instruction

    waiting = await turn(dialogue, "Nie wiem, rozglądam się")
    moved_on = await turn(dialogue, "Jest bezpiecznie")

    assert "jeszcze nie spełnił warunku" in waiting
    assert "Upewnij się, że Ty, poszkodowany i świadkowie" in waiting  # repeats the last unit
    assert "potrząśnij" in moved_on


async def test_an_unusable_reply_of_the_router_keeps_the_cursor() -> None:
    # A digit buried in words is not trusted: a wrong step is worse than waiting.
    for reply in ["nie wiem", "", "9", "Odpowiedź: 1", "Pasują 1 i 2"]:
        dialogue, _ = make([BLS, reply])
        await turn(dialogue, "Nie rusza się")

        task = await turn(dialogue, "Jest bezpiecznie")

        assert "jeszcze nie spełnił warunku" in task, reply


async def test_an_interrupted_answer_is_said_again() -> None:
    dialogue, _ = make([BLS])
    first = await dialogue.begin_turn("Nie rusza się", [])  # never completed: cancelled

    again = await turn(dialogue, "Halo?")

    assert first == again


async def test_choking_that_ends_in_unconsciousness_continues_as_cpr() -> None:
    # recognise -> encourage_cough -> back_blows -> abdominal_thrusts -> call_and_alternate
    # (three instructions) -> unresponsive -> hand-off to adult-bls/chest_compressions
    dialogue, _ = make([CHOKING, "1", "3", "2", "2", "2", "1"])
    await turn(dialogue, "Dławi się")  # recognise
    await turn(dialogue, "Tak")  # encourage_cough
    await turn(dialogue, "Nie kaszle")  # back_blows
    await turn(dialogue, "Nie pomogło")  # abdominal_thrusts
    await turn(dialogue, "Nie pomogło")  # call_and_alternate
    await turn(dialogue)
    await turn(dialogue)
    await turn(dialogue, "Stracił przytomność")  # unresponsive

    task = await turn(dialogue, "Dobrze")

    assert "Uklęknij obok poszkodowanego" in task


async def test_a_finished_scenario_gives_no_new_steps() -> None:
    dialogue, llm = make([CHOKING, "1", "2"])
    await turn(dialogue, "Dławi się")  # recognise
    await turn(dialogue, "Tak")  # encourage_cough
    await turn(dialogue, "Wypluł")  # relieved, its only instruction
    calls = len(llm.calls)

    task = await turn(dialogue, "Dziękuję")

    assert "procedura jest zakończona" in task
    assert len(llm.calls) == calls


def test_websocket_gives_the_model_one_instruction_per_question() -> None:
    llm = ScriptedLLM([BLS, "Upewnij się, że nic wam nie zagraża.", "1", "Potrząśnij go."])
    app = create_app("configs/fake.yaml")
    app.state.llm = llm
    client = TestClient(app)

    with client.websocket_connect("/v1/chat") as ws:
        _ask(ws, "a1", "Kolega leży i się nie rusza", [])
        _ask(
            ws,
            "a2",
            "Jest bezpiecznie",
            [
                {"role": "user", "content": "Kolega leży i się nie rusza"},
                {"role": "assistant", "content": "Upewnij się, że nic wam nie zagraża."},
            ],
        )

    answering = [c for c in llm.calls if c[0].role == "system"]
    first, second = (
        answering[0][-1].content,
        answering[1][-1].content,
    )  # the task is in the last message
    assert "Ty, poszkodowany i świadkowie" in first
    assert "potrząśnij" not in first
    assert "potrząśnij" in second
    assert "Ty, poszkodowany i świadkowie" not in second


async def test_when_the_user_cannot_call_the_scenario_goes_straight_to_the_breathing_check() -> (
    None
):
    dialogue, _ = make([BLS, "1", "1"], intents=["POTWIERDZENIE", "POTWIERDZENIE", "PRZESZKODA"])
    for text in ["Nie rusza się", "Jest bezpiecznie", "Nie reaguje"]:
        await turn(dialogue, text)

    task = await turn(dialogue, "Nie mogę zadzwonić")

    assert "Ułóż poszkodowanego na plecach" in task  # check_breathing, instruction 1
    assert "zostaw" not in task.lower()  # the rescuer is never sent away


async def test_a_question_outside_the_procedure_is_answered_without_moving_on() -> None:
    dialogue, _ = make(
        [BLS, "1", "1"], intents=["POTWIERDZENIE", "POTWIERDZENIE", "INNE", "POTWIERDZENIE"]
    )
    for text in ["Nie rusza się", "Jest bezpiecznie", "Nie reaguje"]:
        await turn(dialogue, text)  # call_emergency, instruction 1 said

    answer = await turn(dialogue, "Mogę mu dać wody?")
    after = await turn(dialogue, "Dobrze")

    assert "Tego nie wiem, zapytaj dyspozytora" in answer
    assert "Ostatnie polecenie" in answer
    assert "poproś, żeby zadzwonił pod sto dwanaście" in answer  # reminds the last instruction
    assert "tryb głośnomówiący" in after  # the instruction was not skipped


async def test_another_problem_is_sent_to_the_dispatcher_only_once_in_a_row() -> None:
    dialogue, _ = make([BLS, "1", "1"], intents=["POTWIERDZENIE", "POTWIERDZENIE", "INNE", "INNE"])
    for text in ["Nie rusza się", "Jest bezpiecznie", "Nie reaguje"]:
        await turn(dialogue, text)

    first = await turn(dialogue, "Co mam robić?")
    second = await turn(dialogue, "Jak to zrobić?")

    assert "Tego nie wiem, zapytaj dyspozytora" in first
    assert "tryb głośnomówiący" in second  # the procedure goes on


async def test_a_stuck_cursor_asks_instead_of_repeating_forever() -> None:
    dialogue, _ = make([BLS, "0", "0", "0", "0"])
    await turn(dialogue, "Nie rusza się")  # safety, its only instruction

    first = await turn(dialogue, "Hm")
    second = await turn(dialogue, "Hm")
    third = await turn(dialogue, "Hm")

    assert "Ostatnie polecenie" in first
    assert "Ostatnie polecenie" in second
    assert "nie powtarzaj poprzedniego polecenia" in third.lower()


async def test_every_turn_names_the_picture_of_its_instruction() -> None:
    dialogue, _ = make(["0", BLS, "1", "1"], intents=["POTWIERDZENIE", "POTWIERDZENIE", "INNE"])

    await turn(dialogue, "Halo")
    no_scenario = dialogue.media
    await turn(dialogue, "Nie rusza się")
    safety = dialogue.media
    await turn(dialogue, "Jest bezpiecznie")
    response = dialogue.media
    await turn(dialogue, "Nie reaguje")
    call = dialogue.media
    await turn(dialogue, "Mogę mu dać wody?")
    question = dialogue.media
    await turn(dialogue, "Dobrze")
    speaker = dialogue.media

    assert no_scenario is None
    assert (safety, response, call) == (
        "cpr/scene-safety",
        "cpr/shake-shoulders",
        "cpr/call-112",
    )
    assert question == "cpr/call-112"  # an answer outside the procedure keeps the picture
    assert speaker == "cpr/speakerphone"


async def test_a_repeated_instruction_keeps_its_picture() -> None:
    dialogue, _ = make([BLS, "0"])
    await turn(dialogue, "Nie rusza się")  # safety, its only instruction

    task = await turn(dialogue, "Nie wiem")

    assert "jeszcze nie spełnił warunku" in task
    assert dialogue.media == "cpr/scene-safety"


def test_websocket_sends_the_picture_before_the_answer() -> None:
    llm = ScriptedLLM([BLS, "Upewnij się, że nic wam nie zagraża."])
    app = create_app("configs/fake.yaml")
    app.state.llm = llm
    client = TestClient(app)

    with client.websocket_connect("/v1/chat") as ws:
        events = _ask(ws, "a1", "Kolega leży i się nie rusza", [])

    assert events[0] == {"type": "step", "id": "a1", "media": "cpr/scene-safety"}
    assert [e["type"] for e in events[1:]] == ["delta", "done"]


def _ask(ws: Any, ask_id: str, text: str, history: list[dict[str, str]]) -> list[dict[str, Any]]:
    ws.send_json({"type": "ask", "id": ask_id, "text": text, "history": history})
    events: list[dict[str, Any]] = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event["type"] == "done" and event["id"] == ask_id:
            return events
