"""
Database lifecycle and connection management.

Uses a module-level connection holder accessed via async context manager.
The schema is applied idempotently on first connect — no migration tool
needed for a single-table SQLite database.
"""

from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import aiosqlite

_SCHEMA = """\
CREATE TABLE IF NOT EXISTS tasks (
    id         TEXT PRIMARY KEY,
    title      TEXT NOT NULL,
    completed  INTEGER NOT NULL DEFAULT 0,
    position   REAL NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tasks_position ON tasks(position);
"""

_DB_PATH_DEFAULT = Path(__file__).parent.parent / "data" / "tasks.db"


def _resolve_db_path() -> str:
    """Resolve database path from environment or default."""
    env_path = os.environ.get("DATABASE_PATH")
    if env_path == ":memory:":
        return ":memory:"
    path = Path(env_path) if env_path else _DB_PATH_DEFAULT
    path.parent.mkdir(parents=True, exist_ok=True)
    return str(path)


class DatabasePool:
    """
    Lightweight async connection pool for aiosqlite.

    aiosqlite runs SQLite in a background thread, so a single connection
    is safe for concurrent FastAPI requests. We keep one long-lived
    connection and expose it via an async context manager for clean
    resource handling.
    """

    def __init__(self) -> None:
        self._conn: aiosqlite.Connection | None = None

    async def connect(self) -> None:
        db_path = _resolve_db_path()
        self._conn = await aiosqlite.connect(db_path)
        self._conn.row_factory = aiosqlite.Row
        await self._conn.execute("PRAGMA journal_mode=WAL")
        await self._conn.execute("PRAGMA foreign_keys=ON")
        await self._conn.executescript(_SCHEMA)
        await self._conn.commit()

    async def disconnect(self) -> None:
        if self._conn:
            await self._conn.close()
            self._conn = None

    @asynccontextmanager
    async def acquire(self) -> AsyncIterator[aiosqlite.Connection]:
        if self._conn is None:
            msg = "Database not connected. Call connect() first."
            raise RuntimeError(msg)
        yield self._conn


# Module-level singleton — imported by the app lifespan and repository.
pool = DatabasePool()
