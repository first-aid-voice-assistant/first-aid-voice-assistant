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

BREATHING = "5"  # number of CHECK_BREATHING in actions.yaml


class DetectingLLM:
    """Answers the event log call with the given numbers and anything else with 'Dobrze.'."""

    name = "detecting"

    def __init__(self, detected: str) -> None:
        self.detected = detected

    async def generate_stream(
        self, messages: list[Message], opts: LLMOptions
    ) -> AsyncIterator[LLMEvent]:
        reply = self.detected if "dziennik czynności" in messages[-1].content else "Dobrze."
        yield LLMDelta(text=reply)
        yield LLMDone(text=reply)


@pytest.fixture
def client(tmp_path: Path) -> TestClient:
    config = yaml.safe_load(Path("configs/fake.yaml").read_text(encoding="utf-8"))
    config["event_log"] = {"enabled": True}
    path = tmp_path / "event_log.yaml"
    path.write_text(yaml.safe_dump(config), encoding="utf-8")
    app = create_app(str(path))
    app.state.llm = DetectingLLM(BREATHING)
    return TestClient(app)


def receive_until_done_and_logged(ws: WebSocketTestSession) -> dict[str, dict[str, Any]]:
    """The answer and the log entry are sent independently, so they come in any order."""
    events: dict[str, dict[str, Any]] = {}
    while not {"done", "action_logged"} <= events.keys():
        event = ws.receive_json()
        events[event["type"]] = event
    return events


def test_recognised_action_is_sent_with_the_time_the_user_finished_speaking(
    client: TestClient,
) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json(
            {
                "type": "ask",
                "id": "a1",
                "text": "Sprawdzam oddech",
                "spoken_at": "2026-11-08T10:15:32+01:00",
            }
        )
        logged = receive_until_done_and_logged(ws)["action_logged"]

    assert logged["id"] == "a1"
    assert logged["entry"]["action"] == "CHECK_BREATHING"
    assert logged["entry"]["transcript"] == "Sprawdzam oddech"
    assert datetime.fromisoformat(logged["entry"]["timestamp"]) == datetime.fromisoformat(
        "2026-11-08T10:15:32+01:00"
    )


def test_without_spoken_at_the_entry_gets_the_time_the_server_received_the_question(
    client: TestClient,
) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json({"type": "ask", "id": "a1", "text": "Sprawdzam oddech"})
        logged = receive_until_done_and_logged(ws)["action_logged"]

    assert datetime.fromisoformat(logged["entry"]["timestamp"]).tzinfo is not None


def test_spoken_at_without_a_time_zone_is_rejected(client: TestClient) -> None:
    with client.websocket_connect("/v1/chat") as ws:
        ws.send_json(
            {"type": "ask", "id": "a1", "text": "Sprawdzam oddech", "spoken_at": "2026-11-08T10:15"}
        )
        event = ws.receive_json()

    assert event == {"type": "error", "id": None, "message": "Invalid message"}
