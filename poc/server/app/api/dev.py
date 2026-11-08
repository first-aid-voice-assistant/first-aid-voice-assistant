"""Dev-only test endpoint: send a transcript, get the model's answer.

Stateless, no history: every request starts a scenario from the beginning.
"""

import logging
import time
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

from app.pipeline.prompt import build_prompt
from app.providers.base import LLMDone, LLMOptions

logger = logging.getLogger(__name__)
router = APIRouter()
_PAGE = Path(__file__).parent / "static" / "dev.html"


class ChatRequest(BaseModel):
    text: str = Field(min_length=1, max_length=2000)


class ChatResponse(BaseModel):
    answer: str
    elapsed_ms: int


@router.get("/dev", response_class=HTMLResponse)
async def dev_page() -> str:
    return _PAGE.read_text(encoding="utf-8")


@router.post("/dev/chat")
async def chat(req: ChatRequest, request: Request) -> ChatResponse:
    state = request.app.state
    started = time.perf_counter()
    answer = ""
    try:
        task = None
        if state.knowledge is not None:
            task = await state.knowledge.dialogue(state.llm).begin_turn(req.text, [])
        messages = build_prompt(state.system_prompt, [], req.text, task)
        async for ev in state.llm.generate_stream(messages, LLMOptions()):
            if isinstance(ev, LLMDone):
                answer = ev.text
    except Exception:
        logger.exception("LLM call failed")
        raise HTTPException(status_code=502, detail="The model failed to answer") from None
    return ChatResponse(answer=answer, elapsed_ms=int((time.perf_counter() - started) * 1000))
