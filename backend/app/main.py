"""
Application entry point.

The FastAPI app uses a lifespan context manager to wire up the database
and repository once at startup, then tear down cleanly on shutdown.
This avoids global mutable state scattered across modules.
"""

from __future__ import annotations

from contextlib import asynccontextmanager
from typing import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import pool
from app.repository import TaskRepository
from app.routes import tasks as task_routes


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Manage database lifecycle — connect on startup, close on shutdown."""
    await pool.connect()
    repo = TaskRepository(pool)
    task_routes.configure(repo)
    yield
    await pool.disconnect()


app = FastAPI(
    title="Mjolnir Todo API",
    description="Offline-first task management backend",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS — permissive in development, locked down in production via env vars.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://127.0.0.1:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(task_routes.router)


@app.get("/health", tags=["system"])
async def health_check() -> dict[str, str]:
    """Lightweight liveness probe."""
    return {"status": "ok"}
