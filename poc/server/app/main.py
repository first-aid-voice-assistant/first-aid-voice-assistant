from pathlib import Path

from fastapi import FastAPI

from app.api import dev, rest, ws
from app.core.config import AppConfig, Settings, load_config
from app.knowledge import KnowledgeRuntime, load_knowledge, load_scenario_prompts
from app.providers.registry import build_llm


def _build_knowledge(config: AppConfig) -> KnowledgeRuntime | None:
    if not config.knowledge.enabled:
        return None
    if config.prompts.knowledge is None:
        raise ValueError("knowledge.enabled needs prompts.knowledge (the scenario prompts file)")
    # A broken knowledge base raises here, so the server does not start with wrong procedures.
    return KnowledgeRuntime(
        load_knowledge(config.knowledge.path), load_scenario_prompts(config.prompts.knowledge)
    )


def create_app(config_path: str | None = None) -> FastAPI:
    settings = Settings()
    config = load_config(config_path or settings.app_config)

    app = FastAPI(title="Voice Assistant")
    app.state.config = config
    app.state.llm = build_llm(config.llm)
    base_prompt = Path(config.prompts.system).read_text(encoding="utf-8")
    app.state.knowledge = _build_knowledge(config)
    app.state.system_prompt = (
        base_prompt
        if app.state.knowledge is None
        else app.state.knowledge.system_prompt(base_prompt)
    )

    app.include_router(rest.router)
    app.include_router(ws.router)
    if settings.dev_mode:
        app.include_router(dev.router)
    return app


app = create_app()
