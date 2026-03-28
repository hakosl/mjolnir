# Mjolnir — Offline-First Task Management

A fast, offline-first todo app with a FastAPI + SQLite backend and React + TypeScript frontend.

## Quick Start

### Backend

```bash
cd backend
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
uvicorn app.main:app --reload --port 8000
```

### Frontend

```bash
cd frontend
npm install
npm run dev
```

The frontend dev server runs on `http://localhost:5173` and proxies API requests to the backend on port 8000.

### Run Tests

```bash
# Backend
cd backend && source .venv/bin/activate && pytest tests/ -v

# Frontend
cd frontend && npx tsc --noEmit
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/api/tasks` | List all tasks (ordered by position) |
| POST | `/api/tasks` | Create a task (`{"title": "..."}`) |
| GET | `/api/tasks/{id}` | Get a single task |
| PUT | `/api/tasks/{id}` | Update a task |
| DELETE | `/api/tasks/{id}` | Delete a task |

## Architecture

- **Backend**: FastAPI → Repository → aiosqlite (SQLite with WAL mode)
- **Frontend**: React + TypeScript + Vite
- **Error handling**: Result monad pattern — no exception-based control flow in the data layer
- **Immutability**: All Pydantic models are frozen; state changes produce new instances

## Tech Stack

- Python 3.12+, FastAPI, aiosqlite, Pydantic v2
- React 19, TypeScript 5.9, Vite 8
