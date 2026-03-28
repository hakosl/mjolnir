"""
Shared test fixtures.

Every test gets a fresh in-memory SQLite database via the `client` fixture,
ensuring complete isolation between tests.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from app.database import DatabasePool
from app.repository import TaskRepository
from app.routes import tasks as task_routes


@pytest.fixture(autouse=True)
def _use_memory_db(monkeypatch: pytest.MonkeyPatch) -> None:
    """Force in-memory database for every test."""
    monkeypatch.setenv("DATABASE_PATH", ":memory:")


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    """
    Yield an httpx AsyncClient with a fully initialized in-memory database.

    Instead of relying on the app lifespan (which ASGITransport doesn't trigger),
    we manually spin up a fresh database pool and wire the repository for each test.
    This gives us full isolation without module-cache tricks.
    """
    os.environ["DATABASE_PATH"] = ":memory:"

    pool = DatabasePool()
    await pool.connect()
    repo = TaskRepository(pool)
    task_routes.configure(repo)

    from app.main import app

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac

    await pool.disconnect()
