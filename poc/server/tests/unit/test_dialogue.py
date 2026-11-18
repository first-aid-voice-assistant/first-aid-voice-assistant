from collections.abc import AsyncIterator
from pathlib import Path
from typing import Any

import yaml
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

    def __init__(
        self,
        replies: list[str],
        intents: list[str] | None = None,
        events: list[str] | None = None,
        interjections: list[str] | None = None,
    ) -> None:
        self.replies = list(replies)
        # Replies of the call that classifies the user's words (POTWIERDZENIE by default).
        self.intents = list(intents or [])
        # Replies of the call that asks whether an event of the step happened ("0" = none).
        self.events = list(events or [])
        # Replies of the verbatim call that classifies words outside the procedure ("0" = other).
        self.interjections = list(interjections or [])
        self.calls: list[list[Message]] = []
        self.event_calls = 0

    async def generate_stream(
        self, messages: list[Message], opts: LLMOptions
    ) -> AsyncIterator[LLMEvent]:
        if "Wybierz jedną etykietę" in messages[0].content:
            reply = self.intents.pop(0) if self.intents else "POTWIERDZENIE"
        elif "zgłasza któreś z poniższych zdarzeń" in messages[0].content:
            self.event_calls += 1
            reply = self.events.pop(0) if self.events else "0"
        elif "nie jest wykonaniem polecenia" in messages[0].content:
            reply = self.interjections.pop(0) if self.interjections else "0"
        else:
            self.calls.append(messages)
            reply = self.replies.pop(0) if self.replies else ""
        yield LLMDelta(text=reply)
        yield LLMDone(text=reply)


def make(
    replies: list[str],
    intents: list[str] | None = None,
    *,
    events: list[str] | None = None,
    interjections: list[str] | None = None,
    verbatim: bool = False,
) -> tuple[ScenarioDialogue, ScriptedLLM]:
    runtime = KnowledgeRuntime(
        load_knowledge(KNOWLEDGE), load_scenario_prompts(SCENARIO_PROMPTS), verbatim=verbatim
    )
    llm = ScriptedLLM(replies, intents, events, interjections)
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
    # call_emergency has three instructions. Safety and response check are one each.
    dialogue, llm = make([BLS, "1", "1"])
    await turn(dialogue, "Nie rusza się")  # safety
    await turn(dialogue, "Jest bezpiecznie")  # check_response
    first = await turn(dialogue, "Nie reaguje")  # call_emergency, instruction 1
    calls_so_far = len(llm.calls)

    second = await turn(dialogue)
    third = await turn(dialogue)

    assert "poproś, żeby zadzwonił pod dziewięćset dziewięćdziesiąt dziewięć" in first
    assert "tryb głośnomówiący" in second
    assert "zostań z poszkodowanym" in third
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
    # Every step ends with a question that the transitions answer: recognise (1 unit),
    # encourage_cough (2 instructions + question), back_blows (2 + question), abdominal_thrusts
    # (3 + question), call_and_alternate (3 + question) -> unresponsive -> hand-off to
    # adult-bls/chest_compressions
    dialogue, _ = make([CHOKING, "1", "3", "2", "2", "2", "1"])
    await turn(dialogue, "Dławi się")  # recognise
    await turn(dialogue, "Tak")  # encourage_cough
    for _ in range(2):
        await turn(dialogue)
    await turn(dialogue, "Nie kaszle")  # back_blows
    for _ in range(2):
        await turn(dialogue)
    await turn(dialogue, "Nie pomogło")  # abdominal_thrusts
    for _ in range(3):
        await turn(dialogue)
    await turn(dialogue, "Nie pomogło")  # call_and_alternate
    for _ in range(3):
        await turn(dialogue)
    await turn(dialogue, "Stracił przytomność")  # unresponsive, instruction 1 (lay on the back)
    await turn(dialogue, "Leży na plecach")  # unresponsive, instruction 2 (call, start CPR)

    task = await turn(dialogue, "Dobrze")

    assert "Uklęknij obok poszkodowanego" in task


async def test_a_finished_scenario_gives_no_new_steps() -> None:
    dialogue, llm = make([CHOKING, "1", "2"])
    await turn(dialogue, "Dławi się")  # recognise
    await turn(dialogue, "Tak")  # encourage_cough
    await turn(dialogue)
    await turn(dialogue)
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

    assert "Spokojnie, robisz dobrze" in answer  # fear
    assert "Dyspozytor Ci to wyjaśni" in answer  # a question outside the procedure
    assert "Powiedz o tym dyspozytorowi" in answer  # something new about the person in need
    assert "nie jest najważniejsze" not in answer  # never dismissed as unimportant
    assert "przypomina ostatnie polecenie" in answer
    assert "Ostatnie polecenie" in answer
    assert (
        "poproś, żeby zadzwonił pod dziewięćset dziewięćdziesiąt dziewięć" in answer
    )  # reminds the last instruction
    assert "tryb głośnomówiący" in after  # the instruction was not skipped


async def test_another_problem_is_sent_to_the_dispatcher_only_once_in_a_row() -> None:
    dialogue, _ = make([BLS, "1", "1"], intents=["POTWIERDZENIE", "POTWIERDZENIE", "INNE", "INNE"])
    for text in ["Nie rusza się", "Jest bezpiecznie", "Nie reaguje"]:
        await turn(dialogue, text)

    first = await turn(dialogue, "Co mam robić?")
    second = await turn(dialogue, "Jak to zrobić?")

    assert "Spokojnie, robisz dobrze" in first
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


async def test_an_unconditional_transition_is_taken_without_asking_the_model() -> None:
    # `when: zawsze` is not a statement to confirm: a model asked about it used to answer
    # "none" and the dialogue repeated the last instruction instead of handing off to CPR.
    dialogue, llm = make([CHOKING])
    await turn(dialogue, "Tata się dławi")
    dialogue._enter(dialogue._scenarios["adult-choking"], "unresponsive")
    await turn(dialogue, "Stracił przytomność")  # says the first of two instructions
    await turn(dialogue, "Leży na plecach")  # says the second one
    calls_before = len(llm.calls)

    task = await turn(dialogue, "Dobrze, zaczynam")

    assert "Uklęknij obok poszkodowanego" in task  # adult-bls/chest_compressions
    assert len(llm.calls) == calls_before  # no side call chose the transition


RECOVERY = "adult-recovery-position"


async def _in_the_middle_of_rolling(events: list[str]) -> tuple[ScenarioDialogue, ScriptedLLM]:
    """roll_to_side has seven instructions; the first one was said, the user answered."""
    dialogue, llm = make([], events=events)
    dialogue._enter(dialogue._scenarios[RECOVERY], "roll_to_side")
    await turn(dialogue, "Zaczynam")  # instruction 1
    return dialogue, llm


async def test_an_event_reported_in_the_middle_of_a_step_is_followed_at_once() -> None:
    # The person stops breathing while the rescuer is still being told how to roll her.
    dialogue, _ = await _in_the_middle_of_rolling(events=["1"])

    task = await turn(dialogue, "Przestała oddychać, chrapie")

    assert "Ułóż poszkodowanego na plecach" in task  # adult-bls/check_breathing, instruction 1
    assert "Rękę leżącą bliżej Ciebie" not in task  # not the second roll instruction


async def test_without_an_event_the_step_goes_on() -> None:
    dialogue, llm = await _in_the_middle_of_rolling(events=["0"])

    task = await turn(dialogue, "Uklęknąłem obok")

    assert "Rękę leżącą bliżej Ciebie" in task
    assert llm.event_calls == 1


async def test_a_step_without_event_branches_never_asks_about_events() -> None:
    # call_emergency has only the phone branch, which is chosen by the intent of the words.
    dialogue, llm = make([BLS])
    await turn(dialogue, "Nie rusza się")
    dialogue._enter(dialogue._scenarios["adult-bls"], "check_response")
    await turn(dialogue, "Nie reaguje")  # check_response, its only instruction
    dialogue._enter(dialogue._scenarios["adult-bls"], "call_emergency")
    await turn(dialogue, "Dzwonię")
    await turn(dialogue, "Włączyłem głośnik")

    assert llm.event_calls == 0


async def test_the_person_stops_responding_during_the_tourniquet() -> None:
    dialogue, _ = make([], events=["1"])
    dialogue._enter(dialogue._scenarios["adult-severe-bleeding"], "tourniquet")
    await turn(dialogue, "Mam opaskę")  # instruction 1 of 5

    task = await turn(dialogue, "Kolega przestał reagować")

    assert "potrząśnij" in task  # adult-bls/check_response


async def test_verbatim_says_the_exact_instruction_and_asks_the_model_only_to_route() -> None:
    dialogue, llm = make([BLS], verbatim=True)

    await turn(dialogue, "Kolega leży i się nie rusza")

    assert dialogue.spoken == "Upewnij się, że Ty, poszkodowany i świadkowie jesteście bezpieczni."
    assert len(llm.calls) == 1  # the model only chose the scenario


async def test_verbatim_repeats_the_last_instruction_word_for_word() -> None:
    dialogue, _ = make([BLS, "0"], verbatim=True)
    await turn(dialogue, "Nie rusza się")  # safety, its only instruction

    await turn(dialogue, "Nie wiem, rozglądam się")

    assert dialogue.spoken == "Upewnij się, że Ty, poszkodowany i świadkowie jesteście bezpieczni."


async def test_verbatim_without_a_procedure_sends_the_caller_to_112() -> None:
    dialogue, _ = make(["0"], verbatim=True)

    await turn(dialogue, "Boli mnie głowa")

    assert dialogue.spoken is not None
    assert "sto dwanaście" in dialogue.spoken
    assert "Nie podaję leków" in dialogue.spoken


async def test_verbatim_reacts_to_words_outside_the_procedure_with_a_fixed_phrase() -> None:
    cases = {
        "1": "Spokojnie, robisz dobrze.",  # fear
        "2": "Dyspozytor Ci to wyjaśni.",  # a question outside the procedure
        "3": "Od razu powiedz o tym dyspozytorowi.",  # something new about the person
        "0": "Spokojnie, spróbuj jeszcze raz.",  # anything else
    }
    for digit, reaction in cases.items():
        dialogue, _ = make(
            [BLS, "1", "1"],
            intents=["POTWIERDZENIE", "POTWIERDZENIE", "INNE"],
            interjections=[digit],
            verbatim=True,
        )
        for text in ["Nie rusza się", "Jest bezpiecznie", "Nie reaguje"]:
            await turn(dialogue, text)  # call_emergency, instruction 1 said

        await turn(dialogue, "Co mam robić?")

        assert dialogue.spoken is not None
        assert dialogue.spoken.startswith(reaction), digit
        # It ends with the last instruction, which is never dismissed.
        assert dialogue.spoken.endswith(
            "pod dziewięćset dziewięćdziesiąt dziewięć. Jeśli jesteś sam, zadzwoń sam."
        )


async def test_the_model_mode_leaves_spoken_empty() -> None:
    dialogue, _ = make([BLS])

    await turn(dialogue, "Nie rusza się")

    assert dialogue.spoken is None


def test_websocket_in_verbatim_mode_sends_the_exact_text_without_asking_the_model(
    tmp_path: Path,
) -> None:
    config = yaml.safe_load(Path("configs/fake.yaml").read_text(encoding="utf-8"))
    config["knowledge"]["verbatim"] = True
    config["knowledge"]["path"] = str(KNOWLEDGE.resolve())
    path = tmp_path / "verbatim.yaml"
    path.write_text(yaml.safe_dump(config, allow_unicode=True), encoding="utf-8")
    llm = ScriptedLLM([BLS])
    app = create_app(str(path))
    app.state.llm = llm
    client = TestClient(app)

    with client.websocket_connect("/v1/chat") as ws:
        events = _ask(ws, "a1", "Kolega leży i się nie rusza", [])

    text = "Upewnij się, że Ty, poszkodowany i świadkowie jesteście bezpieczni."
    assert [e["type"] for e in events] == ["step", "delta", "done"]
    assert events[1]["text"] == text
    assert events[2]["text"] == text
    assert len(llm.calls) == 1  # only the call that chose the scenario
