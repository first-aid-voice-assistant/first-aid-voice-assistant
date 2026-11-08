"""Chat over a WebSocket: the answer is streamed while it is generated.

The client keeps the conversation and sends the history with every question. The only state
the server holds is the position in the first-aid scenario (`ScenarioDialogue`), for as long as
the connection lives. One answer runs at a time: a new question or a `cancel` stops the one in
progress (e.g. when the user starts speaking again).
"""

import asyncio
import contextlib
import logging
import time
from datetime import UTC, datetime
from typing import Annotated, Literal

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import AwareDatetime, BaseModel, Field, TypeAdapter, ValidationError

from app.eventlog import EventLogEntry, EventLogRecorder
from app.knowledge import ScenarioDialogue
from app.pipeline.prompt import build_prompt
from app.providers.base import LLMDelta, LLMDone, LLMOptions, LLMProvider, Message

logger = logging.getLogger(__name__)
router = APIRouter()


class HistoryMessage(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=4000)


class AskMessage(BaseModel):
    type: Literal["ask"]
    id: str = Field(min_length=1, max_length=64)
    text: str = Field(min_length=1, max_length=2000)
    history: list[HistoryMessage] = Field(default_factory=list, max_length=50)
    # When the user finished speaking (ISO 8601 with a time zone); it stamps the event log entries.
    # Without it the time the server received the question is used.
    spoken_at: AwareDatetime | None = None


class CancelMessage(BaseModel):
    type: Literal["cancel"]
    id: str = Field(min_length=1, max_length=64)


ClientMessage = Annotated[AskMessage | CancelMessage, Field(discriminator="type")]
_client_message: TypeAdapter[AskMessage | CancelMessage] = TypeAdapter(ClientMessage)


class DeltaEvent(BaseModel):
    type: Literal["delta"] = "delta"
    id: str
    text: str


class DoneEvent(BaseModel):
    type: Literal["done"] = "done"
    id: str
    text: str
    first_token_ms: int | None
    total_ms: int


class CancelledEvent(BaseModel):
    type: Literal["cancelled"] = "cancelled"
    id: str


class ErrorEvent(BaseModel):
    type: Literal["error"] = "error"
    id: str | None
    message: str


class ActionLoggedEvent(BaseModel):
    """A rescue action recognised in the user's words; the client keeps it in its event log."""

    type: Literal["action_logged"] = "action_logged"
    id: str  # id of the question the action was reported in
    entry: EventLogEntry


ServerEvent = DeltaEvent | DoneEvent | CancelledEvent | ErrorEvent | ActionLoggedEvent


class _ChatSession:
    def __init__(
        self,
        ws: WebSocket,
        llm: LLMProvider,
        system_prompt: str,
        dialogue: ScenarioDialogue | None = None,
        recorder: EventLogRecorder | None = None,
    ) -> None:
        self._ws = ws
        self._llm = llm
        self._system_prompt = system_prompt
        self._dialogue = dialogue
        self._recorder = recorder
        # Event log calls outlive the answer: what the user did is true even if they interrupt it.
        self._logging: set[asyncio.Task[None]] = set()
        # Answers stream from a task while the receive loop keeps reading; the lock keeps
        # their frames from interleaving with frames sent by the loop.
        self._send_lock = asyncio.Lock()
        self._current: tuple[str, asyncio.Task[None]] | None = None

    async def run(self) -> None:
        try:
            while True:
                await self._handle(await self._ws.receive_text())
        except WebSocketDisconnect:
            pass
        finally:
            await self._stop_current(notify=False)
            for task in list(self._logging):
                task.cancel()
            await asyncio.gather(*self._logging, return_exceptions=True)

    async def _handle(self, raw: str) -> None:
        try:
            msg = _client_message.validate_json(raw)
        except ValidationError:
            await self._send(ErrorEvent(id=None, message="Invalid message"))
            return
        if isinstance(msg, CancelMessage):
            if self._current is not None and self._current[0] == msg.id:
                await self._stop_current(notify=True)
            return
        await self._stop_current(notify=True)
        if self._recorder is not None:
            spoken_at = msg.spoken_at or datetime.now(UTC)
            logging_task = asyncio.create_task(self._log_actions(msg, self._recorder, spoken_at))
            self._logging.add(logging_task)
            logging_task.add_done_callback(self._logging.discard)
        self._current = (msg.id, asyncio.create_task(self._answer(msg)))

    async def _stop_current(self, *, notify: bool) -> None:
        current, self._current = self._current, None
        if current is None:
            return
        ask_id, task = current
        if task.done():
            return
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        if notify:
            await self._send(CancelledEvent(id=ask_id))

    async def _answer(self, msg: AskMessage) -> None:
        history = [Message(role=m.role, content=m.content) for m in msg.history]
        started = time.perf_counter()
        first_token_ms: int | None = None
        try:
            task = None
            if self._dialogue is not None:
                task = await self._dialogue.begin_turn(msg.text, history)
            messages = build_prompt(self._system_prompt, history, msg.text, task)
            async for ev in self._llm.generate_stream(messages, LLMOptions()):
                if isinstance(ev, LLMDelta):
                    if first_token_ms is None:
                        first_token_ms = _elapsed_ms(started)
                    await self._send(DeltaEvent(id=msg.id, text=ev.text))
                elif isinstance(ev, LLMDone):
                    # Before sending, so that a quick next question cannot overtake it.
                    if self._dialogue is not None:
                        self._dialogue.turn_completed()
                    await self._send(
                        DoneEvent(
                            id=msg.id,
                            text=ev.text,
                            first_token_ms=first_token_ms,
                            total_ms=_elapsed_ms(started),
                        )
                    )
        except asyncio.CancelledError:
            raise
        except WebSocketDisconnect:
            return
        except Exception:
            logger.exception("LLM call failed")
            with contextlib.suppress(Exception):
                await self._send(ErrorEvent(id=msg.id, message="The model failed to answer"))

    async def _log_actions(
        self, msg: AskMessage, recorder: EventLogRecorder, spoken_at: datetime
    ) -> None:
        history = [Message(role=m.role, content=m.content) for m in msg.history]
        try:
            for entry in await recorder.record(msg.text, history, spoken_at):
                await self._send(ActionLoggedEvent(id=msg.id, entry=entry))
        except asyncio.CancelledError:
            raise
        except WebSocketDisconnect:
            return
        except Exception:
            # The answer matters more than the log, and an error event would make the client
            # show its "call 112" fallback; so this is only logged on the server.
            logger.exception("Event log call failed")

    async def _send(self, event: ServerEvent) -> None:
        async with self._send_lock:
            await self._ws.send_text(event.model_dump_json())


def _elapsed_ms(started: float) -> int:
    return int((time.perf_counter() - started) * 1000)


@router.websocket("/v1/chat")
async def chat(ws: WebSocket) -> None:
    await ws.accept()
    state = ws.app.state
    knowledge = state.knowledge
    dialogue = knowledge.dialogue(state.llm) if knowledge is not None else None
    event_log = state.event_log
    recorder = event_log.recorder(state.llm) if event_log is not None else None
    await _ChatSession(ws, state.llm, state.system_prompt, dialogue, recorder).run()
