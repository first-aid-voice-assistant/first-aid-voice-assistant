"""Turns the codes the dialogue reports for an utterance into event log entries.

The dialogue knows which action the user confirmed and which observation a scenario branch
recorded (see `ScenarioDialogue.logged`); no model is asked. The state lives as long as the
object, i.e. one WebSocket connection; the log itself is kept by the phone.
"""

import uuid
from datetime import datetime
from typing import Literal

from app.eventlog.models import EventLogEntry
from app.knowledge.models import Action


class EventLogRecorder:
    def __init__(
        self, actions: list[Action], source: Literal["local", "cloud"] | None = None
    ) -> None:
        self._kinds = {a.code: a.kind for a in actions}
        self._source = source
        self._started: datetime | None = None  # time of the first entry
        self._last_action: str | None = None

    def record(self, codes: list[str], user_text: str, spoken_at: datetime) -> list[EventLogEntry]:
        """Entries for `codes`, reported in `user_text` that ended at `spoken_at`.

        An action repeated right after itself ("I am pressing", "still pressing") is one continuing
        action, so it is logged once; it can be logged again after another action. Observations
        are always logged and do not interrupt that chain. An unknown code is ignored.
        """
        entries: list[EventLogEntry] = []
        for code in codes:
            kind = self._kinds.get(code)
            if kind is None:
                continue
            if kind == "action":
                if code == self._last_action:
                    continue
                self._last_action = code
            if self._started is None:
                self._started = spoken_at
            entries.append(
                EventLogEntry(
                    id=uuid.uuid4().hex,
                    timestamp=spoken_at,
                    # Utterances can arrive out of order or with a skewed phone clock.
                    elapsed_s=max(0.0, (spoken_at - self._started).total_seconds()),
                    action=code,
                    transcript=user_text,
                    source=self._source,
                )
            )
        return entries
