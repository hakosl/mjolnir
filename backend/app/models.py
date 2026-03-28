"""
Pydantic models for the Task domain.

Three separate models enforce a clear contract at each boundary:
- TaskCreate: what the client sends to create a task
- TaskUpdate: what the client sends to modify a task (all fields optional)
- Task: the canonical representation returned from the API

All models are frozen (immutable) — state changes produce new instances.
"""

from __future__ import annotations

from datetime import datetime, timezone
from uuid import UUID, uuid4

from pydantic import BaseModel, Field, field_validator

TITLE_MIN_LENGTH = 1
TITLE_MAX_LENGTH = 500


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


class TaskCreate(BaseModel, frozen=True):
    """Inbound model for task creation. Only title is required."""

    title: str = Field(..., min_length=TITLE_MIN_LENGTH, max_length=TITLE_MAX_LENGTH)

    @field_validator("title", mode="before")
    @classmethod
    def strip_and_validate(cls, v: str) -> str:
        if isinstance(v, str):
            stripped = v.strip()
            if not stripped:
                msg = "Title cannot be empty or whitespace"
                raise ValueError(msg)
            return stripped
        return v


class TaskUpdate(BaseModel, frozen=True):
    """Inbound model for task updates. Every field is optional."""

    title: str | None = Field(None, min_length=TITLE_MIN_LENGTH, max_length=TITLE_MAX_LENGTH)
    completed: bool | None = None

    @field_validator("title", mode="before")
    @classmethod
    def strip_and_validate(cls, v: str | None) -> str | None:
        if isinstance(v, str):
            stripped = v.strip()
            if not stripped:
                msg = "Title cannot be empty or whitespace"
                raise ValueError(msg)
            return stripped
        return v


class Task(BaseModel, frozen=True):
    """Canonical task representation — the single source of truth shape."""

    id: UUID = Field(default_factory=uuid4)
    title: str
    completed: bool = False
    position: float = 0.0
    created_at: datetime = Field(default_factory=_utc_now)
    updated_at: datetime = Field(default_factory=_utc_now)

    def with_updates(self, **changes: object) -> Task:
        """Return a new Task with the given fields replaced."""
        data = self.model_dump()
        data.update(changes)
        data["updated_at"] = _utc_now()
        return Task.model_validate(data)
