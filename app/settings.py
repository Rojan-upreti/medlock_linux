from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


def project_dir() -> Path:
    env = os.environ.get("PROJECT_DIR")
    if env:
        return Path(env).expanduser().resolve()
    return Path(__file__).resolve().parent.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=str(project_dir() / ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    PROJECT_DIR: Path = Field(default_factory=project_dir)
    MODEL_DIR: Path | None = None
    MODEL_PATH: str = ""
    MMPROJ_PATH: str = ""
    EMBEDDING_MODEL_PATH: str = ""
    EMBEDDING_MODEL_NAME: str = "BAAI/bge-small-en-v1.5"
    LLAMACPP_DIR: str = ""
    LLAMA_SERVER_BIN: str = ""

    MEDLOCK_HOST: str = "127.0.0.1"
    MEDLOCK_PORT: int = 8000
    LLAMA_HOST: str = "127.0.0.1"
    LLAMA_PORT: int = 8081
    CHAT_HOSTNAME: str = "medlock.chat"
    ADMIN_HOSTNAME: str = "medlock.admin"
    SERVED_MODEL_NAME: str = "medlock-llm"

    LLAMA_API_KEY: str = ""
    MEDLOCK_ADMIN_TOKEN: str = ""
    MEDLOCK_SESSION_SECRET: str = ""
    NEMOCLAW_LLAMACPP_LOCAL_TOKEN: str = ""

    DATABASE_URL: str = "sqlite:///data/medlock.sqlite"
    POSTGRES_USER: str = "medlock"
    POSTGRES_PASSWORD: str = ""
    POSTGRES_DB: str = "medlock"
    POSTGRES_HOST: str = "127.0.0.1"
    POSTGRES_PORT: int = 5432

    SERVICENOW_ENABLED: bool = False
    SERVICENOW_INSTANCE_URL: str = ""
    SERVICENOW_CLIENT_ID: str = ""
    SERVICENOW_CLIENT_SECRET: str = ""

    MEDLOCK_DEMO: bool = False
    LOG_LEVEL: str = "INFO"
    MEDLOCK_DATA: str = ""
    MEDLOCK_DATA_ROOT: str = ""
    MEDLOCK_WORKSPACE: str = ""
    WORKSPACE_NAME: str = ""

    def data_dir(self) -> Path:
        raw = (self.MEDLOCK_DATA or "").strip()
        if raw:
            path = Path(raw).expanduser().resolve()
        else:
            path = self.PROJECT_DIR
        path.mkdir(parents=True, exist_ok=True)
        return path

    def yaml_config(self) -> dict[str, Any]:
        path = self.PROJECT_DIR / "config" / "local.yaml"
        if not path.is_file():
            return {}
        return yaml.safe_load(path.read_text(encoding="utf-8")) or {}

    def cloud_llm_blocked(self) -> bool:
        cfg = self.yaml_config()
        inf = cfg.get("inference") or {}
        if inf.get("allow_cloud_llm") is True:
            return False
        if inf.get("mode") not in (None, "local"):
            return False
        return True

    def llama_base(self) -> str:
        return f"http://{self.LLAMA_HOST}:{self.LLAMA_PORT}"


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
