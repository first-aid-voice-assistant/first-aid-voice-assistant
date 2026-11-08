"""Loads `knowledge/` and checks that its references are consistent.

Fails loudly: a scenario that points at a missing step, action or source must stop the server
from starting rather than reach the model.
"""

from pathlib import Path

import yaml

from app.knowledge.models import (
    ActionDictionary,
    KnowledgeBase,
    Scenario,
    Source,
)

ACTIONS_FILE = "actions.yaml"


class KnowledgeError(ValueError):
    pass


def load_knowledge(root: str | Path) -> KnowledgeBase:
    root = Path(root)
    sources = [Source.model_validate(_read(p)) for p in sorted((root / "sources").glob("*.yaml"))]
    scenarios_dir = root / "scenarios"
    actions = ActionDictionary.model_validate(_read(scenarios_dir / ACTIONS_FILE)).actions
    scenarios = [
        Scenario.model_validate(_read(p))
        for p in sorted(scenarios_dir.glob("*.yaml"))
        if p.name != ACTIONS_FILE
    ]
    kb = KnowledgeBase(sources=sources, actions=actions, scenarios=scenarios)
    _check_references(kb)
    return kb


def _read(path: Path) -> object:
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def _check_references(kb: KnowledgeBase) -> None:
    problems: list[str] = []
    sections = {s.id: set(s.sections) for s in kb.sources}
    action_codes = [a.code for a in kb.actions]
    scenarios = {s.id: s for s in kb.scenarios}

    _duplicates(problems, "source", [s.id for s in kb.sources])
    _duplicates(problems, "action", action_codes)
    _duplicates(problems, "scenario", list(scenarios))
    if not kb.scenarios:
        problems.append("no scenarios found")

    for sc in kb.scenarios:
        step_ids = [s.id for s in sc.steps]
        _duplicates(problems, f"step in {sc.id}", step_ids)
        if sc.start not in step_ids:
            problems.append(f"{sc.id}: start step '{sc.start}' does not exist")
        for step in sc.steps:
            where = f"{sc.id}/{step.id}"
            for code in step.actions:
                if code not in action_codes:
                    problems.append(f"{where}: unknown action '{code}'")
            # Citations are checked only when source descriptions are present (the sources
            # folder may be empty while the procedures are still being drafted).
            for ref in step.sources if sections else []:
                if ref.source not in sections:
                    problems.append(f"{where}: unknown source '{ref.source}'")
                elif not _section_known(ref.section, sections[ref.source]):
                    problems.append(
                        f"{where}: section '{ref.section}' is not listed in source '{ref.source}'"
                    )
            for tr in step.transitions:
                if tr.goto is not None and tr.goto not in step_ids:
                    problems.append(f"{where}: transition to unknown step '{tr.goto}'")
                if tr.handoff is not None:
                    target, _, target_step = tr.handoff.partition("/")
                    if target not in scenarios or target_step not in {
                        s.id for s in scenarios[target].steps
                    }:
                        problems.append(f"{where}: hand-off to unknown '{tr.handoff}'")
        problems.extend(_unreachable(sc))

    if problems:
        raise KnowledgeError("invalid knowledge base:\n- " + "\n- ".join(problems))


def _section_known(ref: str, known: set[str]) -> bool:
    # A step may cite a part of a listed section ("<section> – <detail>").
    return any(ref == s or ref.startswith(f"{s} –") or ref.startswith(f"{s};") for s in known)


def _duplicates(problems: list[str], what: str, ids: list[str]) -> None:
    for i in sorted({i for i in ids if ids.count(i) > 1}):
        problems.append(f"duplicate {what} id '{i}'")


def _unreachable(sc: Scenario) -> list[str]:
    reached: set[str] = set()
    todo = [sc.start]
    while todo:
        sid = todo.pop()
        if sid in reached or sid not in {s.id for s in sc.steps}:
            continue
        reached.add(sid)
        todo.extend(t.goto for t in sc.step(sid).transitions if t.goto is not None)
    return [f"{sc.id}: step '{s.id}' is unreachable" for s in sc.steps if s.id not in reached]
