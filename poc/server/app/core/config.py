from pathlib import Path
from typing import Any

import yaml
from pydantic import BaseModel, Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class ProviderConfig(BaseModel):
    provider: str
    params: dict[str, Any] = Field(default_factory=dict)
    hotwords_file: str | None = None


class RAGConfig(BaseModel):
    enabled: bool = False


class KnowledgeConfig(BaseModel):
    """Scenarios from `knowledge/` put into the system prompt (see app/knowledge)."""

    enabled: bool = False
    path: str = "../../knowledge"  # repository root's knowledge/, relative to poc/server/


class PromptsConfig(BaseModel):
    system: str
    knowledge: str | None = None  # template of the knowledge section; needed when it is enabled


class AppConfig(BaseModel):
    asr: ProviderConfig
    llm: ProviderConfig
    rag: RAGConfig = Field(default_factory=RAGConfig)
    knowledge: KnowledgeConfig = Field(default_factory=KnowledgeConfig)
    prompts: PromptsConfig


class Settings(BaseSettings):
    """Environment variables (.env). Model setup lives in the YAML file (AppConfig)."""

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_config: str = "configs/base.yaml"
    redis_url: str = "redis://redis:6379/0"
    dev_mode: bool = False  # exposes the /dev test page; never enable in production


def load_config(path: str | Path) -> AppConfig:
    with open(path, encoding="utf-8") as f:
        return AppConfig.model_validate(yaml.safe_load(f))
