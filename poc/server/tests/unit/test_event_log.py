from datetime import UTC, datetime, timedelta

from app.eventlog import EventLogRecorder
from app.knowledge import load_knowledge

KNOWLEDGE = "../../knowledge"
START = datetime(2026, 11, 8, 10, 0, tzinfo=UTC)


def recorder() -> EventLogRecorder:
    return EventLogRecorder(load_knowledge(KNOWLEDGE).actions)


def test_an_entry_has_the_words_the_time_and_the_seconds_since_the_first_entry() -> None:
    log = recorder()

    first = log.record(["CALL_EMERGENCY"], "Dzwonię", START)
    second = log.record(["CHEST_COMPRESSIONS"], "Uciskam", START + timedelta(seconds=75))

    assert [(e.action, e.transcript, e.elapsed_s) for e in first + second] == [
        ("CALL_EMERGENCY", "Dzwonię", 0),
        ("CHEST_COMPRESSIONS", "Uciskam", 75),
    ]
    assert second[0].timestamp == START + timedelta(seconds=75)


def test_an_action_repeated_right_after_itself_is_logged_once() -> None:
    log = recorder()

    entries = [
        *log.record(["CHEST_COMPRESSIONS"], "Uciskam", START),
        *log.record(["CHEST_COMPRESSIONS"], "Nadal uciskam", START + timedelta(seconds=10)),
    ]

    assert [e.action for e in entries] == ["CHEST_COMPRESSIONS"]


def test_an_action_is_logged_again_after_another_one() -> None:
    log = recorder()

    entries = [
        *log.record(["CHEST_COMPRESSIONS"], "Uciskam", START),
        *log.record(["RESCUE_BREATHS"], "Dwa oddechy", START + timedelta(seconds=30)),
        *log.record(["CHEST_COMPRESSIONS"], "Wracam do uciskania", START + timedelta(seconds=40)),
    ]

    assert [e.action for e in entries] == [
        "CHEST_COMPRESSIONS",
        "RESCUE_BREATHS",
        "CHEST_COMPRESSIONS",
    ]


def test_observations_are_always_logged_and_do_not_break_a_continuing_action() -> None:
    log = recorder()

    entries = [
        *log.record(["CHEST_COMPRESSIONS"], "Uciskam", START),
        *log.record(["UNRESPONSIVE"], "Znowu nie reaguje", START + timedelta(seconds=5)),
        *log.record(["UNRESPONSIVE"], "Nie reaguje", START + timedelta(seconds=9)),
        *log.record(["CHEST_COMPRESSIONS"], "Uciskam dalej", START + timedelta(seconds=12)),
    ]

    assert [e.action for e in entries] == ["CHEST_COMPRESSIONS", "UNRESPONSIVE", "UNRESPONSIVE"]


def test_an_unknown_code_is_ignored() -> None:
    assert recorder().record(["NOT_IN_THE_DICTIONARY"], "Cokolwiek", START) == []


def test_a_skewed_clock_never_gives_a_negative_elapsed_time() -> None:
    log = recorder()
    log.record(["CALL_EMERGENCY"], "Dzwonię", START)

    [entry] = log.record(["CHECK_BREATHING"], "Patrzę", START - timedelta(seconds=3))

    assert entry.elapsed_s == 0
