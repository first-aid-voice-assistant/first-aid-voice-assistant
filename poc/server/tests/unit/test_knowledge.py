import shutil
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
import yaml
from fastapi.testclient import TestClient

from app.knowledge import KnowledgeError, load_knowledge, load_scenario_prompts
from app.knowledge.models import Scenario
from app.main import create_app

KNOWLEDGE = Path("../../knowledge")
SCENARIO_PROMPTS = Path("prompts/scenario_v1.yaml")


@pytest.fixture
def kb_copy(tmp_path: Path) -> Path:
    """A throw-away copy of the real scenarios (no sources folder) to break in tests."""
    root = tmp_path / "knowledge"
    shutil.copytree(
        KNOWLEDGE / "scenarios", root / "scenarios", ignore=shutil.ignore_patterns("README.md")
    )
    return root


def _write_source(root: Path, source_id: str, sections: list[str]) -> None:
    (root / "sources").mkdir(exist_ok=True)
    data = {
        "id": source_id,
        "title": "t",
        "publisher": "p",
        "version": "1",
        "urls": ["https://example.org"],
        "accessed": "2026-01-01",
        "sections": sections,
    }
    (root / "sources" / f"{source_id}.yaml").write_text(yaml.safe_dump(data), encoding="utf-8")


def _edit_scenario(root: Path, name: str, change: Callable[[dict[str, Any]], None]) -> None:
    path = root / "scenarios" / f"{name}.yaml"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    change(data)
    path.write_text(yaml.safe_dump(data, allow_unicode=True), encoding="utf-8")


def test_real_knowledge_base_is_valid() -> None:
    kb = load_knowledge(KNOWLEDGE)

    assert {s.id for s in kb.scenarios} >= {
        "adult-bls",
        "adult-choking",
        "adult-recovery-position",
        "adult-severe-bleeding",
    }
    assert {a.code for a in kb.actions} >= {"CHEST_COMPRESSIONS", "BACK_BLOWS"}


def test_bls_scenario_keeps_the_official_numbers() -> None:
    kb = load_knowledge(KNOWLEDGE)
    text = " ".join(u for sc in kb.scenarios for st in sc.steps for u in st.units)

    # ERC 2025: 5-6 cm, 100-120 per minute, 30:2, 5 back blows, 10 seconds for two breaths.
    assert "co najmniej pięciu, ale nie więcej niż sześciu centymetrów" in text
    assert "od stu do stu dwudziestu uciśnięć na minutę" in text
    assert "trzydzieści uciśnięć do dwóch oddechów" in text
    assert "do pięciu uderzeń w plecy" in text
    assert "nie dłużej niż dziesięć sekund" in text


def test_bls_calls_for_help_before_checking_breathing() -> None:
    bls = next(s for s in load_knowledge(KNOWLEDGE).scenarios if s.id == "adult-bls")
    order = [bls.start]
    while bls.step(order[-1]).transitions and len(order) < 10:
        order.append(bls.step(order[-1]).transitions[0].goto or "")
        if order[-1] in order[:-1]:
            break

    assert order.index("call_emergency") < order.index("check_breathing")


def test_choking_escalates_from_cough_to_back_blows_to_abdominal_thrusts() -> None:
    choking = next(s for s in load_knowledge(KNOWLEDGE).scenarios if s.id == "adult-choking")

    def targets(step_id: str) -> set[str | None]:
        return {t.goto for t in choking.step(step_id).transitions}

    assert "back_blows" in targets("encourage_cough")
    assert "abdominal_thrusts" in targets("back_blows")
    assert "call_and_alternate" in targets("abdominal_thrusts")


def _scenario(scenario_id: str) -> Scenario:
    return next(s for s in load_knowledge(KNOWLEDGE).scenarios if s.id == scenario_id)


def test_every_step_cites_the_erc_guidelines() -> None:
    kb = load_knowledge(KNOWLEDGE)

    assert {s.id for s in kb.sources} == {"erc-2025-bls", "erc-2025-first-aid"}
    for sc in kb.scenarios:
        for step in sc.steps:
            assert step.sources, f"{sc.id}/{step.id} cites no source"


def test_recovery_position_is_not_used_after_trauma() -> None:
    recovery = _scenario("adult-recovery-position")
    start = recovery.step(recovery.start)

    by_goto = {t.goto: t.when for t in start.transitions if t.goto}

    assert "roll_to_side" in by_goto
    assert "uraz" in by_goto["trauma_keep_still"]
    assert "ROLL_TO_RECOVERY_POSITION" not in recovery.step("trauma_keep_still").actions


def test_unresponsive_but_breathing_person_goes_to_the_recovery_position() -> None:
    bls = _scenario("adult-bls")

    handoffs = [t.handoff for t in bls.step("breathing_normally").transitions]

    assert handoffs == ["adult-recovery-position/check_trauma"]


def test_tourniquet_is_offered_only_after_direct_pressure_failed() -> None:
    bleeding = _scenario("adult-severe-bleeding")
    reaches_tourniquet = {
        step.id
        for step in bleeding.steps
        if any(t.goto in {"tourniquet", "tourniquet_check"} for t in step.transitions)
    }

    assert reaches_tourniquet == {"direct_pressure", "tourniquet_check"}
    assert "APPLY_TOURNIQUET" not in bleeding.step("direct_pressure").actions
    assert "pięciu do siedmiu centymetrów" in " ".join(bleeding.step("tourniquet").units)
    assert "Zapisz na opasce godzinę" in " ".join(bleeding.step("tourniquet").units)


def test_bls_uses_the_aed_and_returns_to_compressions() -> None:
    bls = _scenario("adult-bls")

    assert {t.goto for t in bls.step("aed_shock").transitions} == {"resume_compressions"}
    assert {t.goto for t in bls.step("aed_analyse").transitions} == {
        "aed_shock",
        "resume_compressions",
    }
    interrupts = {t.goto for t in bls.step("compressions_30_2").transitions if t.interrupt}
    assert interrupts == {"aed_attach", "aed_analyse"}


def test_citations_are_not_checked_without_source_files(kb_copy: Path) -> None:
    _edit_scenario(
        kb_copy, "adult-bls", lambda d: d["steps"][0]["sources"][0].update(source="made-up")
    )

    assert load_knowledge(kb_copy).sources == []


def test_unknown_step_in_transition_is_rejected(kb_copy: Path) -> None:
    _edit_scenario(
        kb_copy, "adult-bls", lambda d: d["steps"][0]["transitions"][0].update(goto="nowhere")
    )

    with pytest.raises(KnowledgeError, match="unknown step 'nowhere'"):
        load_knowledge(kb_copy)


def test_unknown_action_is_rejected(kb_copy: Path) -> None:
    _edit_scenario(kb_copy, "adult-bls", lambda d: d["steps"][1].update(actions=["NOT_AN_ACTION"]))

    with pytest.raises(KnowledgeError, match="unknown action 'NOT_AN_ACTION'"):
        load_knowledge(kb_copy)


def test_unknown_source_is_rejected(kb_copy: Path) -> None:
    _write_source(kb_copy, "erc-2025-bls", ["Safety"])
    _edit_scenario(
        kb_copy, "adult-bls", lambda d: d["steps"][0]["sources"][0].update(source="made-up")
    )

    with pytest.raises(KnowledgeError, match="unknown source 'made-up'"):
        load_knowledge(kb_copy)


def test_section_missing_from_the_source_is_rejected(kb_copy: Path) -> None:
    _write_source(kb_copy, "erc-2025-bls", ["Safety"])
    _edit_scenario(
        kb_copy, "adult-bls", lambda d: d["steps"][0]["sources"][1].update(section="Invented")
    )

    with pytest.raises(KnowledgeError, match="section 'Invented' is not listed"):
        load_knowledge(kb_copy)


def test_unreachable_step_is_rejected(kb_copy: Path) -> None:
    _edit_scenario(
        kb_copy,
        "adult-choking",
        lambda d: d["steps"].append(
            {
                "id": "orphan",
                "instructions": ["x"],
                "sources": [{"source": "erc-2025-first-aid", "section": "Choking in an adult"}],
            }
        ),
    )

    with pytest.raises(KnowledgeError, match="'orphan' is unreachable"):
        load_knowledge(kb_copy)


def test_every_bls_instruction_has_a_picture() -> None:
    bls = next(s for s in load_knowledge(KNOWLEDGE).scenarios if s.id == "adult-bls")

    pictures = [m for step in bls.steps for m in step.unit_media]

    assert None not in pictures
    assert bls.step("compressions_only").unit_media == ["cpr/compressions", "cpr/compressions"]
    # The ask shows the picture of the last instruction.
    assert bls.step("check_breathing").unit_media[-1] == "cpr/check-breathing"


def test_instruction_without_a_picture_in_a_scenario_with_pictures_is_rejected(
    kb_copy: Path,
) -> None:
    def change(d: dict[str, Any]) -> None:
        step = next(s for s in d["steps"] if s["id"] == "call_emergency")
        step["instructions"][1] = step["instructions"][1]["text"]

    _edit_scenario(kb_copy, "adult-bls", change)

    with pytest.raises(KnowledgeError, match="call_emergency: instruction 2 has no media"):
        load_knowledge(kb_copy)


def test_malformed_media_key_is_rejected(kb_copy: Path) -> None:
    _edit_scenario(kb_copy, "adult-bls", lambda d: d["steps"][0].update(media="Compressions.gif"))

    with pytest.raises(ValueError, match="media"):
        load_knowledge(kb_copy)


def test_handoff_to_unknown_scenario_is_rejected(kb_copy: Path) -> None:
    def change(d: dict[str, Any]) -> None:
        step = next(s for s in d["steps"] if s["id"] == "unresponsive")
        step["transitions"][0]["handoff"] = "adult-bls/missing"

    _edit_scenario(kb_copy, "adult-choking", change)

    with pytest.raises(KnowledgeError, match="hand-off to unknown 'adult-bls/missing'"):
        load_knowledge(kb_copy)


def test_scenario_prompts_have_the_placeholders_the_dialogue_fills_in() -> None:
    prompts = load_scenario_prompts(SCENARIO_PROMPTS)

    assert "{instruction}" in prompts.say
    assert "{last}" in prompts.repeat
    assert "{titles}" in prompts.idle
    assert "{messages}" in prompts.route_scenario
    assert "{options}" in prompts.route_scenario
    assert "{assistant}" in prompts.route_step
    assert "{user}" in prompts.route_step
    assert "{options}" in prompts.route_step


def test_system_prompt_has_the_safety_rules_and_no_whole_procedure() -> None:
    client = TestClient(create_app("configs/fake.yaml"))

    prompt: str = client.app.state.system_prompt  # type: ignore[attr-defined]

    assert "Zasady bezpieczeństwa" in prompt
    assert "BIEŻĄCE ZADANIE" in prompt  # the rules that explain the per-turn task
    assert "Delikatnie potrząśnij" not in prompt  # procedures reach the model one step at a time


def test_knowledge_disabled_leaves_the_plain_system_prompt(tmp_path: Path) -> None:
    config = tmp_path / "plain.yaml"
    text = Path("configs/fake.yaml").read_text(encoding="utf-8")
    config.write_text(text.replace("enabled: true", "enabled: false"), encoding="utf-8")

    app = create_app(str(config))

    assert app.state.knowledge is None
    assert app.state.system_prompt == Path("prompts/system_v1.md").read_text(encoding="utf-8")


def test_knowledge_needs_the_scenario_prompts_file(tmp_path: Path) -> None:
    config = tmp_path / "broken.yaml"
    text = Path("configs/fake.yaml").read_text(encoding="utf-8")
    config.write_text(text.replace(", knowledge: prompts/scenario_v1.yaml", ""), encoding="utf-8")

    with pytest.raises(ValueError, match="needs prompts.knowledge"):
        create_app(str(config))
