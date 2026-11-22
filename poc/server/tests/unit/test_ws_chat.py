from collections.abc import AsyncIterator
from typing import Any

import pytest
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession

from app.main import create_app
from app.providers.base import LLMEvent
from app.providers.llm.fake import FakeLLM

SLOW_REPLY = "Zadzwoń pod numer sto dwanaście i włącz tryb głośnomówiący teraz."


@pytest.fixture
def client() -> TestClient:
    app = create_app("configs/fake.yaml")
    app.state.llm = FakeLLM()  # echoes the input, which makes the prompt observable
    return TestClient(app)


def receive_until(ws: WebSocketTestSession, kind: str, ask_id: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event["type"] == kind and event["id"] == ask_id:
            return events


def test_answer_is_streamed_and_ends_with_done(client: TestClient) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "Kolega nie oddycha"})
        events = receive_until(ws, "done", "a1")

    step, *deltas, done = events
    assert step["type"] == "step"  # the scenarios are on in fake.yaml
    assert len(deltas) > 1
    assert all(e["type"] == "delta" and e["id"] == "a1" for e in deltas)
    assert "".join(e["text"] for e in deltas) == done["text"]
    assert "Kolega nie oddycha" in done["text"]
    assert done["first_token_ms"] >= 0
    assert done["total_ms"] >= done["first_token_ms"]


def test_history_is_sent_to_the_model(client: TestClient) -> None:
    history = [
        {"role": "user", "content": "Ktoś upadł"},
        {"role": "assistant", "content": "Czy oddycha?"},
    ]
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "Nie", "history": history})
        done = receive_until(ws, "done", "a1")[-1]

    # FakeLLM reports the message count: system prompt + 2 history messages + user text.
    assert "4 messages" in done["text"]


def test_cancel_stops_the_answer(client: TestClient) -> None:
    client.app.state.llm = FakeLLM(reply=SLOW_REPLY, delay=0.05)  # type: ignore[attr-defined]
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "hej"})
        assert ws.receive_json()["type"] == "step"
        assert ws.receive_json()["type"] == "delta"
        ws.send_json({"type": "cancel", "id": "a1"})
        events = receive_until(ws, "cancelled", "a1")
        ws.send_json({"type": "ask", "id": "a2", "text": "hej"})
        after = ws.receive_json()

    assert all(e["type"] == "delta" for e in events[:-1])
    assert after["id"] == "a2"


def test_new_question_replaces_the_answer_in_progress(client: TestClient) -> None:
    client.app.state.llm = FakeLLM(reply=SLOW_REPLY, delay=0.05)  # type: ignore[attr-defined]
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "Ktoś upadł"})
        assert ws.receive_json()["id"] == "a1"
        ws.send_json({"type": "ask", "id": "a2", "text": "On jednak oddycha"})
        receive_until(ws, "cancelled", "a1")
        events = receive_until(ws, "done", "a2")

    assert all(e["id"] == "a2" for e in events)
    assert events[-1]["text"] == SLOW_REPLY


def test_cancel_of_another_answer_is_ignored(client: TestClient) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "cancel", "id": "old"})
        ws.send_json({"type": "ask", "id": "a1", "text": "hej"})
        events = receive_until(ws, "done", "a1")

    assert {e["type"] for e in events} == {"step", "delta", "done"}


def test_model_failure_is_reported_as_error(client: TestClient) -> None:
    class Boom:
        name = "boom"

        async def generate_stream(self, *args: Any, **kwargs: Any) -> AsyncIterator[LLMEvent]:
            raise RuntimeError("model down")
            yield  # pragma: no cover - makes this an async generator

    client.app.state.llm = Boom()  # type: ignore[attr-defined]
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "hej"})
        event = ws.receive_json()

    assert event == {"type": "error", "id": "a1", "message": "The model failed to answer"}


@pytest.mark.parametrize(
    "message",
    [
        {"type": "ask", "id": "a1", "text": ""},
        {"type": "ask", "text": "hej"},
        {"type": "shout", "id": "a1"},
        {"type": "ask", "id": "a1", "text": "hej", "history": [{"role": "system", "content": "x"}]},
    ],
)
def test_invalid_message_is_reported_and_connection_stays_open(
    client: TestClient, message: dict[str, Any]
) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json(message)
        error = ws.receive_json()
        ws.send_json({"type": "ask", "id": "a2", "text": "hej"})
        done = receive_until(ws, "done", "a2")[-1]

    assert error == {"type": "error", "id": None, "message": "Invalid message"}
    assert done["type"] == "done"
