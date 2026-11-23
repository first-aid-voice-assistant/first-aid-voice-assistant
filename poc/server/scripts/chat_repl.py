"""Interactive terminal client for `WS /v1/chat`: talk to the assistant like the mobile app does.

Unlike `POST /dev/chat`, the connection keeps the position in the first-aid scenario, and this
client keeps the history and sends it with every question (as the app does). The answer is
printed as it streams in. Like the app, it stamps every question with `spoken_at` (the moment the
line was entered) and keeps the event log built from the `action_logged` events, if the server
sends them (`event_log.enabled` in its config).

Usage:
    uv run python scripts/chat_repl.py
    uv run python scripts/chat_repl.py --url ws://localhost:8000/v1/chat
    uv run python scripts/chat_repl.py --script rozmowa.txt   # one user utterance per line

Commands inside the chat: /log (show the event log), /reset (new connection, scenario and log
from the start), /quit. The log is shown at the end of the conversation too.
"""

import argparse
import asyncio
import json
import sys
from collections.abc import Iterator
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import websockets
from websockets.asyncio.client import ClientConnection

_FALLBACK = "Jeśli to sytuacja zagrożenia życia, zadzwoń pod 112."


class _EventLog:
    """Entries received so far. They may arrive after the `done` of their question."""

    def __init__(self) -> None:
        self.entries: list[dict[str, Any]] = []
        self._shown = 0

    def add(self, event: dict[str, Any]) -> None:
        self.entries.append(event["entry"])

    def show_new(self) -> None:
        for entry in self.entries[self._shown :]:
            print(f"          [log] {_format(entry)}")
        self._shown = len(self.entries)

    def show_all(self) -> None:
        print("\n=== Dziennik zdarzeń ===" if self.entries else "\n[dziennik zdarzeń jest pusty]")
        for entry in self.entries:
            print(_format(entry))


def _format(entry: dict[str, Any]) -> str:
    clock = datetime.fromisoformat(entry["timestamp"]).astimezone().strftime("%H:%M:%S")
    return f"{clock} (+{entry['elapsed_s']:.0f} s) {entry['action']} – „{entry['transcript']}”"


async def _ask(
    ws: ClientConnection, ask_id: str, text: str, history: list[dict[str, str]], log: _EventLog
) -> str:
    """Sends one question, prints the streamed answer and returns the full text ('' on error)."""
    message = {
        "type": "ask",
        "id": ask_id,
        "text": text,
        "history": history,
        "spoken_at": datetime.now(UTC).isoformat(),
    }
    await ws.send(json.dumps(message))
    print("asystent> ", end="", flush=True)
    while True:
        event: dict[str, Any] = json.loads(await ws.recv())
        if event["type"] == "action_logged":  # also of an earlier question
            log.add(event)
            continue
        if event.get("id") not in (ask_id, None):
            continue
        match event["type"]:
            case "step":
                print(f"[{event['media'] or 'bez obrazka'}] ", end="", flush=True)
            case "delta":
                print(event["text"], end="", flush=True)
            case "done":
                first = event["first_token_ms"]
                print(f"\n          [{event['total_ms']} ms, first token {first} ms]")
                log.show_new()
                return str(event["text"])
            case "cancelled":
                print("\n[cancelled]")
                return ""
            case "error":
                print(f"\n[error: {event['message']}] {_FALLBACK}")
                return ""


async def _collect_late_entries(ws: ClientConnection, log: _EventLog, quiet_s: float) -> None:
    """Reads events until none came for `quiet_s` seconds.

    The server sends the log entry of a question independently of its answer (it can come
    later), and does not say when it is done, so we wait for a quiet moment.
    """
    while True:
        try:
            event = json.loads(await asyncio.wait_for(ws.recv(), quiet_s))
        except TimeoutError:
            return
        if event["type"] == "action_logged":
            log.add(event)


def _lines(script: Path | None) -> Iterator[str]:
    """User utterances: from a file (one per line) or typed in the terminal."""
    if script is not None:
        for line in script.read_text(encoding="utf-8").splitlines():
            if line.strip() and not line.startswith("#"):
                print(f"ty> {line}")
                yield line.strip()
        return
    while True:
        try:
            yield input("ty> ").strip()
        except EOFError:
            return


async def _chat(url: str, script: Path | None, log_wait: float) -> None:
    history: list[dict[str, str]] = []
    log = _EventLog()
    turn = 0
    ws = await websockets.connect(url)

    async def show_log() -> None:
        await _collect_late_entries(ws, log, log_wait)
        log.show_all()

    try:
        for line in _lines(script):
            if not line:
                continue
            if line == "/quit":
                break
            if line == "/log":
                await show_log()
                continue
            if line == "/reset":
                if log.entries:
                    await show_log()
                await ws.close()
                ws = await websockets.connect(url)
                history, turn, log = [], 0, _EventLog()
                print("[new connection, scenario and event log start from the beginning]")
                continue
            turn += 1
            answer = await _ask(ws, f"t{turn}", line, history, log)
            if answer:
                history += [
                    {"role": "user", "content": line},
                    {"role": "assistant", "content": answer},
                ]
        if turn:
            await _collect_late_entries(ws, log, log_wait)
            if log.entries:
                log.show_all()
    finally:
        await ws.close()


def main() -> None:
    # The Windows console defaults to a legacy code page and garbles Polish letters.
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0] if __doc__ else None)
    parser.add_argument("--url", default="ws://localhost:8000/v1/chat")
    parser.add_argument("--script", type=Path, help="file with one user utterance per line")
    parser.add_argument(
        "--log-wait",
        type=float,
        default=3.0,
        help="seconds of silence to wait for late event log entries before showing the log",
    )
    args = parser.parse_args()
    try:
        asyncio.run(_chat(args.url, args.script, args.log_wait))
    except (OSError, websockets.WebSocketException):
        print(f"[cannot talk to {args.url}] {_FALLBACK}")
        sys.exit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
