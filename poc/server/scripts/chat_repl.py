"""Interactive terminal client for `WS /v1/chat`: talk to the assistant like the mobile app does.

Unlike `POST /dev/chat`, the connection keeps the position in the first-aid scenario, and this
client keeps the history and sends it with every question (as the app does). The answer is
printed as it streams in.

Usage:
    uv run python scripts/chat_repl.py
    uv run python scripts/chat_repl.py --url ws://localhost:8000/v1/chat
    uv run python scripts/chat_repl.py --script rozmowa.txt   # one user utterance per line

Commands inside the chat: /reset (new connection, scenario from the start), /quit.
"""

import argparse
import asyncio
import json
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import websockets
from websockets.asyncio.client import ClientConnection

_FALLBACK = "Jeśli to sytuacja zagrożenia życia, zadzwoń pod 112."


async def _ask(ws: ClientConnection, ask_id: str, text: str, history: list[dict[str, str]]) -> str:
    """Sends one question, prints the streamed answer and returns the full text ('' on error)."""
    await ws.send(json.dumps({"type": "ask", "id": ask_id, "text": text, "history": history}))
    print("asystent> ", end="", flush=True)
    while True:
        event: dict[str, Any] = json.loads(await ws.recv())
        if event.get("id") not in (ask_id, None):
            continue
        match event["type"]:
            case "delta":
                print(event["text"], end="", flush=True)
            case "done":
                first = event["first_token_ms"]
                print(f"\n          [{event['total_ms']} ms, first token {first} ms]")
                return str(event["text"])
            case "cancelled":
                print("\n[cancelled]")
                return ""
            case "error":
                print(f"\n[error: {event['message']}] {_FALLBACK}")
                return ""


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


async def _chat(url: str, script: Path | None) -> None:
    history: list[dict[str, str]] = []
    turn = 0
    ws = await websockets.connect(url)
    try:
        for line in _lines(script):
            if not line:
                continue
            if line == "/quit":
                return
            if line == "/reset":
                await ws.close()
                ws = await websockets.connect(url)
                history, turn = [], 0
                print("[new connection, scenario starts from the beginning]")
                continue
            turn += 1
            answer = await _ask(ws, f"t{turn}", line, history)
            if answer:
                history += [
                    {"role": "user", "content": line},
                    {"role": "assistant", "content": answer},
                ]
    finally:
        await ws.close()


def main() -> None:
    # The Windows console defaults to a legacy code page and garbles Polish letters.
    sys.stdout.reconfigure(encoding="utf-8")  # type: ignore[union-attr]
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0] if __doc__ else None)
    parser.add_argument("--url", default="ws://localhost:8000/v1/chat")
    parser.add_argument("--script", type=Path, help="file with one user utterance per line")
    args = parser.parse_args()
    try:
        asyncio.run(_chat(args.url, args.script))
    except (OSError, websockets.WebSocketException):
        print(f"[cannot talk to {args.url}] {_FALLBACK}")
        sys.exit(1)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
