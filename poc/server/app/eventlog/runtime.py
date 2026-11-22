from dataclasses import dataclass

from app.eventlog.recorder import EventLogRecorder
from app.knowledge.models import Action


@dataclass
class EventLogRuntime:
    """What the server needs to fill the event log: the dictionary of actions and observations."""

    actions: list[Action]

    def recorder(self) -> EventLogRecorder:
        """A recorder for one connection (it remembers the last logged action)."""
        return EventLogRecorder(self.actions)
