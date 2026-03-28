"""
Task repository — the only module that touches SQL.

Every public method returns a Result[T, str] so callers never need
try/except for expected failures (not found, constraint violations).
Unexpected errors still raise to be caught by the global handler.

The repository is stateless — it receives a DatabasePool at construction
and uses it for every operation. This makes testing trivial: inject a
pool backed by :memory: SQLite.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Sequence
from uuid import UUID, uuid4

from app.database import DatabasePool
from app.models import Task, TaskCreate, TaskUpdate
from app.result import Err, Ok, Result


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _row_to_task(row: dict) -> Task:
    """Convert a sqlite Row (dict-like) to an immutable Task model."""
    return Task(
        id=UUID(row["id"]),
        title=row["title"],
        completed=bool(row["completed"]),
        position=float(row["position"]),
        created_at=datetime.fromisoformat(row["created_at"]),
        updated_at=datetime.fromisoformat(row["updated_at"]),
    )


class TaskRepository:
    """Pure data-access layer for tasks. No business logic lives here."""

    def __init__(self, pool: DatabasePool) -> None:
        self._pool = pool

    async def list_all(self) -> Result[Sequence[Task], str]:
        """Return all tasks ordered by position ascending."""
        async with self._pool.acquire() as conn:
            cursor = await conn.execute("SELECT * FROM tasks ORDER BY position ASC")
            rows = await cursor.fetchall()
            return Ok(tuple(_row_to_task(dict(row)) for row in rows))

    async def find_by_id(self, task_id: UUID) -> Result[Task, str]:
        """Find a single task by its UUID."""
        async with self._pool.acquire() as conn:
            cursor = await conn.execute("SELECT * FROM tasks WHERE id = ?", (str(task_id),))
            row = await cursor.fetchone()
            if row is None:
                return Err(f"Task {task_id} not found")
            return Ok(_row_to_task(dict(row)))

    async def create(self, payload: TaskCreate) -> Result[Task, str]:
        """
        Insert a new task. Position is auto-assigned as max(position) + 1.0,
        which keeps new tasks at the bottom of the list by default.
        """
        async with self._pool.acquire() as conn:
            cursor = await conn.execute("SELECT COALESCE(MAX(position), 0.0) FROM tasks")
            row = await cursor.fetchone()
            next_position = (row[0] if row else 0.0) + 1.0

            now = _utc_now()
            task = Task(
                id=uuid4(),
                title=payload.title,
                completed=False,
                position=next_position,
                created_at=now,
                updated_at=now,
            )

            await conn.execute(
                """
                INSERT INTO tasks (id, title, completed, position, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    str(task.id),
                    task.title,
                    int(task.completed),
                    task.position,
                    task.created_at.isoformat(),
                    task.updated_at.isoformat(),
                ),
            )
            await conn.commit()
            return Ok(task)

    async def update(self, task_id: UUID, payload: TaskUpdate) -> Result[Task, str]:
        """
        Apply partial updates to a task. Only non-None fields are changed.
        Returns the full updated task or Err if not found.
        """
        existing = await self.find_by_id(task_id)
        if existing.is_err:
            return existing  # type: ignore[return-value]

        task = existing.value  # type: ignore[union-attr]
        changes: dict[str, object] = {}
        if payload.title is not None:
            changes["title"] = payload.title
        if payload.completed is not None:
            changes["completed"] = payload.completed

        if not changes:
            return Ok(task)

        updated = task.with_updates(**changes)

        async with self._pool.acquire() as conn:
            await conn.execute(
                """
                UPDATE tasks
                SET title = ?, completed = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    updated.title,
                    int(updated.completed),
                    updated.updated_at.isoformat(),
                    str(task_id),
                ),
            )
            await conn.commit()
            return Ok(updated)

    async def delete(self, task_id: UUID) -> Result[None, str]:
        """Delete a task. Returns Err if the task doesn't exist."""
        async with self._pool.acquire() as conn:
            cursor = await conn.execute("DELETE FROM tasks WHERE id = ?", (str(task_id),))
            await conn.commit()
            if cursor.rowcount == 0:
                return Err(f"Task {task_id} not found")
            return Ok(None)

    async def next_position(self) -> float:
        """Calculate the next available position value."""
        async with self._pool.acquire() as conn:
            cursor = await conn.execute("SELECT COALESCE(MAX(position), 0.0) FROM tasks")
            row = await cursor.fetchone()
            return (row[0] if row else 0.0) + 1.0
