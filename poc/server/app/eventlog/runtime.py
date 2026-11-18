from dataclasses import dataclass

from app.eventlog.detector import ActionDetector
from app.eventlog.prompts import EventLogPrompts
from app.eventlog.recorder import EventLogRecorder
from app.knowledge.models import Action
from app.providers.base import LLMProvider


@dataclass
class EventLogRuntime:
    """What the server needs to fill the event log: the action dictionary and the prompts."""

    actions: list[Action]
    prompts: EventLogPrompts

    def recorder(self, llm: LLMProvider) -> EventLogRecorder:
        """A recorder for one connection (it remembers the last logged action)."""
        return EventLogRecorder(ActionDetector(llm, self.actions, self.prompts))
