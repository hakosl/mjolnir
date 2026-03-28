"""
Comprehensive tests for the Task CRUD API.

Tests are organized by HTTP method, with edge cases grouped logically.
Each test is independent — no test relies on state from another.
"""

from __future__ import annotations

from uuid import UUID

import pytest
from httpx import AsyncClient


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _create_task(client: AsyncClient, title: str = "Buy milk") -> dict:
    """Shorthand: create a task and return the response JSON."""
    resp = await client.post("/api/tasks", json={"title": title})
    assert resp.status_code == 201
    return resp.json()


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------


class TestHealthCheck:
    async def test_returns_ok(self, client: AsyncClient) -> None:
        resp = await client.get("/health")
        assert resp.status_code == 200
        assert resp.json() == {"status": "ok"}


# ---------------------------------------------------------------------------
# POST /api/tasks
# ---------------------------------------------------------------------------


class TestCreateTask:
    async def test_creates_with_valid_title(self, client: AsyncClient) -> None:
        body = await _create_task(client, "Buy milk")
        assert body["title"] == "Buy milk"
        assert body["completed"] is False
        assert isinstance(body["position"], float)
        # Verify all expected fields are present
        assert UUID(body["id"])
        assert body["created_at"]
        assert body["updated_at"]

    async def test_strips_whitespace(self, client: AsyncClient) -> None:
        body = await _create_task(client, "  Trim me  ")
        assert body["title"] == "Trim me"

    async def test_rejects_empty_title(self, client: AsyncClient) -> None:
        resp = await client.post("/api/tasks", json={"title": ""})
        assert resp.status_code == 422

    async def test_rejects_whitespace_only_title(self, client: AsyncClient) -> None:
        resp = await client.post("/api/tasks", json={"title": "   "})
        assert resp.status_code == 422

    async def test_rejects_missing_title(self, client: AsyncClient) -> None:
        resp = await client.post("/api/tasks", json={})
        assert resp.status_code == 422

    async def test_rejects_title_over_500_chars(self, client: AsyncClient) -> None:
        long_title = "x" * 501
        resp = await client.post("/api/tasks", json={"title": long_title})
        assert resp.status_code == 422

    async def test_accepts_title_at_500_chars(self, client: AsyncClient) -> None:
        exact_title = "x" * 500
        body = await _create_task(client, exact_title)
        assert len(body["title"]) == 500

    async def test_sequential_positions_increase(self, client: AsyncClient) -> None:
        first = await _create_task(client, "First")
        second = await _create_task(client, "Second")
        assert second["position"] > first["position"]

    async def test_ids_are_unique_uuids(self, client: AsyncClient) -> None:
        a = await _create_task(client, "Task A")
        b = await _create_task(client, "Task B")
        assert UUID(a["id"]) != UUID(b["id"])


# ---------------------------------------------------------------------------
# GET /api/tasks
# ---------------------------------------------------------------------------


class TestListTasks:
    async def test_returns_empty_list_initially(self, client: AsyncClient) -> None:
        resp = await client.get("/api/tasks")
        assert resp.status_code == 200
        assert resp.json() == []

    async def test_returns_all_tasks_ordered_by_position(self, client: AsyncClient) -> None:
        await _create_task(client, "First")
        await _create_task(client, "Second")
        await _create_task(client, "Third")

        resp = await client.get("/api/tasks")
        tasks = resp.json()
        assert len(tasks) == 3
        positions = [t["position"] for t in tasks]
        assert positions == sorted(positions)
        assert [t["title"] for t in tasks] == ["First", "Second", "Third"]


# ---------------------------------------------------------------------------
# GET /api/tasks/{id}
# ---------------------------------------------------------------------------


class TestGetTask:
    async def test_retrieves_existing_task(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.get(f"/api/tasks/{created['id']}")
        assert resp.status_code == 200
        assert resp.json()["id"] == created["id"]

    async def test_returns_404_for_nonexistent(self, client: AsyncClient) -> None:
        fake_id = "00000000-0000-0000-0000-000000000000"
        resp = await client.get(f"/api/tasks/{fake_id}")
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# PUT /api/tasks/{id}
# ---------------------------------------------------------------------------


class TestUpdateTask:
    async def test_updates_title(self, client: AsyncClient) -> None:
        created = await _create_task(client, "Old title")
        resp = await client.put(
            f"/api/tasks/{created['id']}", json={"title": "New title"}
        )
        assert resp.status_code == 200
        assert resp.json()["title"] == "New title"

    async def test_updates_completed(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.put(
            f"/api/tasks/{created['id']}", json={"completed": True}
        )
        assert resp.status_code == 200
        assert resp.json()["completed"] is True

    async def test_updates_both_fields(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.put(
            f"/api/tasks/{created['id']}",
            json={"title": "Updated", "completed": True},
        )
        body = resp.json()
        assert body["title"] == "Updated"
        assert body["completed"] is True

    async def test_updated_at_changes(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.put(
            f"/api/tasks/{created['id']}", json={"title": "Changed"}
        )
        assert resp.json()["updated_at"] >= created["updated_at"]

    async def test_returns_404_for_nonexistent(self, client: AsyncClient) -> None:
        fake_id = "00000000-0000-0000-0000-000000000000"
        resp = await client.put(f"/api/tasks/{fake_id}", json={"title": "Nope"})
        assert resp.status_code == 404

    async def test_rejects_empty_title_update(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.put(
            f"/api/tasks/{created['id']}", json={"title": ""}
        )
        assert resp.status_code == 422

    async def test_no_op_update_returns_unchanged(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.put(f"/api/tasks/{created['id']}", json={})
        assert resp.status_code == 200
        assert resp.json()["title"] == created["title"]


# ---------------------------------------------------------------------------
# DELETE /api/tasks/{id}
# ---------------------------------------------------------------------------


class TestDeleteTask:
    async def test_deletes_existing_task(self, client: AsyncClient) -> None:
        created = await _create_task(client)
        resp = await client.delete(f"/api/tasks/{created['id']}")
        assert resp.status_code == 204

        # Verify it's actually gone
        resp = await client.get(f"/api/tasks/{created['id']}")
        assert resp.status_code == 404

    async def test_returns_404_for_nonexistent(self, client: AsyncClient) -> None:
        fake_id = "00000000-0000-0000-0000-000000000000"
        resp = await client.delete(f"/api/tasks/{fake_id}")
        assert resp.status_code == 404

    async def test_delete_reduces_list_count(self, client: AsyncClient) -> None:
        t1 = await _create_task(client, "Keep")
        t2 = await _create_task(client, "Remove")
        await client.delete(f"/api/tasks/{t2['id']}")

        resp = await client.get("/api/tasks")
        tasks = resp.json()
        assert len(tasks) == 1
        assert tasks[0]["id"] == t1["id"]
