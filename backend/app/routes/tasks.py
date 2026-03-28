"""
Task API routes.

Thin routing layer: validates input (via Pydantic), delegates to the
repository, and translates Result values into HTTP responses. No SQL,
no business logic — just request → result → response.
"""

from __future__ import annotations

from typing import Sequence
from uuid import UUID

from fastapi import APIRouter, HTTPException, Response, status

from app.models import Task, TaskCreate, TaskUpdate
from app.repository import TaskRepository

router = APIRouter(prefix="/api/tasks", tags=["tasks"])

# The repository instance is injected at app startup (see main.py).
_repo: TaskRepository | None = None


def configure(repo: TaskRepository) -> None:
    """Wire the repository into the route module. Called once at startup."""
    global _repo  # noqa: PLW0603
    _repo = repo


def _get_repo() -> TaskRepository:
    if _repo is None:
        raise RuntimeError("TaskRepository not configured — call configure() first")
    return _repo


@router.get("", response_model=Sequence[Task], status_code=status.HTTP_200_OK)
async def list_tasks() -> Sequence[Task]:
    """List every task, ordered by position."""
    result = await _get_repo().list_all()
    if result.is_err:
        raise HTTPException(status_code=500, detail="Failed to retrieve tasks")
    return result.value  # type: ignore[union-attr]


@router.post("", response_model=Task, status_code=status.HTTP_201_CREATED)
async def create_task(payload: TaskCreate) -> Task:
    """Create a new task from the given title."""
    result = await _get_repo().create(payload)
    if result.is_err:
        raise HTTPException(status_code=500, detail="Failed to create task")
    return result.value  # type: ignore[union-attr]


@router.get("/{task_id}", response_model=Task, status_code=status.HTTP_200_OK)
async def get_task(task_id: UUID) -> Task:
    """Retrieve a single task by ID."""
    result = await _get_repo().find_by_id(task_id)
    if result.is_err:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=result.reason,  # type: ignore[union-attr]
        )
    return result.value  # type: ignore[union-attr]


@router.put("/{task_id}", response_model=Task, status_code=status.HTTP_200_OK)
async def update_task(task_id: UUID, payload: TaskUpdate) -> Task:
    """Apply partial updates to a task."""
    result = await _get_repo().update(task_id, payload)
    if result.is_err:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=result.reason,  # type: ignore[union-attr]
        )
    return result.value  # type: ignore[union-attr]


@router.delete("/{task_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_task(task_id: UUID) -> Response:
    """Delete a task. Returns 204 on success, 404 if not found."""
    result = await _get_repo().delete(task_id)
    if result.is_err:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=result.reason,  # type: ignore[union-attr]
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
