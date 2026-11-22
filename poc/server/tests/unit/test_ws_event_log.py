from collections.abc import AsyncIterator
from datetime import datetime
from pathlib import Path
from typing import Any

import pytest
import yaml
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession

from app.main import create_app
from app.providers.base import LLMDelta, LLMDone, LLMEvent, LLMOptions, Message

BLS = "1"  # alphabetical order of the scenario files, as the router lists them


class RoutingLLM:
    """Plays the side calls of the dialogue (scenario, intent, event, transition) and counts them.

    Every side call is a single user message; the answer has the system prompt first.
    """

    name = "routing"

    def __init__(self, transition: str = "1") -> None:
        self.transition = transition
        self.side_calls = 0

    async def generate_stream(
        self, messages: list[Message], opts: LLMOptions
    ) -> AsyncIterator[LLMEvent]:
        text = messages[0].content
        if messages[0].role == "system":
            reply = "Dobrze."  # the answer the user hears
        else:
            self.side_calls += 1
            if "Wybierz procedurę pierwszej pomocy" in text:
                reply = BLS
            elif "Wybierz jedną etykietę" in text:
                reply = "POTWIERDZENIE"
            elif "zgłasza któreś z poniższych zdarzeń" in text:
                reply = "0"
            else:
                reply = self.transition  # the transition the user's words satisfy
        yield LLMDelta(text=reply)
        yield LLMDone(text=reply)


def make_client(tmp_path: Path, *, event_log: bool = True) -> tuple[TestClient, RoutingLLM]:
    config = yaml.safe_load(Path("configs/fake.yaml").read_text(encoding="utf-8"))
    config["event_log"] = {"enabled": event_log}
    path = tmp_path / "event_log.yaml"
    path.write_text(yaml.safe_dump(config, allow_unicode=True), encoding="utf-8")
    app = create_app(str(path))
    llm = RoutingLLM()
    app.state.llm = llm
    return TestClient(app), llm


def ask(ws: WebSocketTestSession, ask_id: str, text: str, **extra: Any) -> list[dict[str, Any]]:
    """Sends a question and returns the events up to its `done` (the log entries come first)."""
    ws.send_json({"type": "ask", "id": ask_id, "text": text, **extra})
    events: list[dict[str, Any]] = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event["type"] == "done" and event["id"] == ask_id:
            return events


def logged(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [e for e in events if e["type"] == "action_logged"]


def test_a_confirmed_action_is_logged_with_the_time_the_user_finished_speaking(
    tmp_path: Path,
) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")  # the assistant asks to check safety
        events = ask(ws, "a2", "Jest bezpiecznie", spoken_at="2026-11-08T10:15:32+01:00")

    [entry] = logged(events)
    assert entry["id"] == "a2"
    assert entry["entry"]["action"] == "CHECK_SAFETY"
    assert entry["entry"]["transcript"] == "Jest bezpiecznie"
    assert datetime.fromisoformat(entry["entry"]["timestamp"]) == datetime.fromisoformat(
        "2026-11-08T10:15:32+01:00"
    )


def test_without_spoken_at_the_entry_gets_the_time_the_server_received_the_question(
    tmp_path: Path,
) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        events = ask(ws, "a2", "Jest bezpiecznie")

    [entry] = logged(events)
    assert datetime.fromisoformat(entry["entry"]["timestamp"]).tzinfo is not None


def test_the_entry_comes_before_the_answer(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        events = ask(ws, "a2", "Jest bezpiecznie")

    assert [e["type"] for e in events][:2] == ["action_logged", "step"]


def test_the_log_costs_no_model_call(tmp_path: Path) -> None:
    # The same conversation with the log off makes exactly as many side calls as with it on.
    counts = []
    for enabled in (False, True):
        client, llm = make_client(tmp_path, event_log=enabled)
        with client.websocket_connect("/v1/chat") as ws:
            ask(ws, "a1", "Kolega leży i się nie rusza")
            ask(ws, "a2", "Jest bezpiecznie")
            ask(ws, "a3", "Potrząsam go, nie reaguje")
        counts.append(llm.side_calls)

    assert counts[0] == counts[1]


def test_an_announcement_is_not_logged(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        events = ask(ws, "a2", "Zaraz sprawdzę")

    assert logged(events) == []


def test_an_observation_follows_the_action_of_the_same_utterance(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        ask(ws, "a2", "Jest bezpiecznie")  # check_response: shake the shoulders
        events = ask(ws, "a3", "Potrząsam go, nie reaguje")

    assert [e["entry"]["action"] for e in logged(events)] == ["CHECK_RESPONSE", "UNRESPONSIVE"]


def test_the_elapsed_time_counts_from_the_first_entry(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        first = ask(ws, "a2", "Jest bezpiecznie", spoken_at="2026-11-08T10:00:00+01:00")
        second = ask(ws, "a3", "Potrząsam go, nie reaguje", spoken_at="2026-11-08T10:01:30+01:00")

    assert logged(first)[0]["entry"]["elapsed_s"] == 0
    assert logged(second)[0]["entry"]["elapsed_s"] == pytest.approx(90)


def test_nothing_is_sent_when_the_event_log_is_off(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path, event_log=False)
    with client.websocket_connect("/v1/chat") as ws:
        ask(ws, "a1", "Kolega leży i się nie rusza")
        events = ask(ws, "a2", "Jest bezpiecznie")

    assert logged(events) == []


def test_spoken_at_without_a_time_zone_is_rejected(tmp_path: Path) -> None:
    client, _ = make_client(tmp_path)
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json(
            {"type": "ask", "id": "a1", "text": "Jest bezpiecznie", "spoken_at": "2026-11-08T10:15"}
        )
        event = ws.receive_json()

    assert event == {"type": "error", "id": None, "message": "Invalid message"}
