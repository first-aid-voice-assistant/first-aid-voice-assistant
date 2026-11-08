"""Turns what the detector recognised into event log entries.

The state lives as long as the object, i.e. one WebSocket connection; the log itself is kept by
the phone. Detections are handled one at a time in the order they were asked for, so that a slow
call for an earlier utterance cannot put its entries after those of a later one.
"""

import asyncio
import uuid
from datetime import datetime
from typing import Literal

from app.eventlog.detector import ActionDetector
from app.eventlog.models import EventLogEntry
from app.providers.base import Message


class EventLogRecorder:
    def __init__(
        self, detector: ActionDetector, source: Literal["local", "cloud"] | None = None
    ) -> None:
        self._detector = detector
        self._source = source
        self._lock = asyncio.Lock()
        self._started: datetime | None = None  # time of the first entry
        self._last_action: str | None = None

    async def record(
        self, user_text: str, history: list[Message], spoken_at: datetime
    ) -> list[EventLogEntry]:
        """Entries for the actions reported in `user_text`, said (finished speaking) at `spoken_at`.

        An action repeated right after itself ("I am pressing", "still pressing") is one
        continuing action, so it is logged once; it can be logged again after another action.
        """
        async with self._lock:
            entries: list[EventLogEntry] = []
            for action in await self._detector.detect(user_text, history):
                if action == self._last_action:
                    continue
                if self._started is None:
                    self._started = spoken_at
                entries.append(
                    EventLogEntry(
                        id=uuid.uuid4().hex,
                        timestamp=spoken_at,
                        # Utterances can arrive out of order or with a skewed phone clock.
                        elapsed_s=max(0.0, (spoken_at - self._started).total_seconds()),
                        action=action,
                        transcript=user_text,
                        source=self._source,
                    )
                )
                self._last_action = action
            return entries
