#!/usr/bin/env python3
"""Atomic state machine for Mjolnir harness."""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

VALID_PHASES = frozenset(
    {
        "idle",
        "planning",
        "generating",
        "testing",
        "evaluating",
        "rate_limited",
        "halted",
        "error",
        "complete",
    }
)


def default_state() -> dict[str, Any]:
    return {
        "phase": "idle",
        "sprint": 0,
        "attempt": 0,
        "total_sprints": 0,
        "last_error": None,
        "rate_limit_until": None,
        "rate_limit_resume_phase": None,
        "started_at": time.time(),
        "updated_at": time.time(),
        "costs": {"planner": 0.0, "generator": 0.0, "tester": 0.0, "evaluator": 0.0},
    }


def _clean_stale_tmp(state_file: str) -> None:
    """Remove leftover .tmp file from a previous crash."""
    tmp_path = Path(f"{state_file}.tmp")
    if tmp_path.exists():
        print(f"[state] stale tmp file found: {tmp_path} — removing", file=sys.stderr)
        tmp_path.unlink()


def read_state(state_file: str) -> dict[str, Any]:
    path = Path(state_file)
    _clean_stale_tmp(state_file)
    if not path.exists():
        return default_state()
    try:
        with open(path) as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"State file corrupted at {path}: {e}") from e


def write_state(state_file: str, state: dict[str, Any]) -> dict[str, Any]:
    """Atomic write: write to .tmp then mv (POSIX atomic rename)."""
    new_state = {**state, "updated_at": time.time()}
    tmp_path = f"{state_file}.tmp"
    with open(tmp_path, "w") as f:
        json.dump(new_state, f, indent=2)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp_path, state_file)
    return new_state


def _with_lock(state_file: str, fn):
    """Execute fn while holding an exclusive file lock on state."""
    lock_path = f"{state_file}.lock"
    with open(lock_path, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return fn()


def transition(state_file: str, new_phase: str, **updates: Any) -> dict[str, Any]:
    """Read state, apply transition, write atomically. Returns new state."""
    if new_phase not in VALID_PHASES:
        raise ValueError(f"Invalid phase: {new_phase}. Valid: {VALID_PHASES}")

    def _do():
        state = read_state(state_file)
        new_state = {**state, "phase": new_phase, **updates}
        return write_state(state_file, new_state)

    return _with_lock(state_file, _do)


VALID_ROLES = frozenset({"planner", "generator", "tester", "evaluator"})


def add_cost(state_file: str, role: str, amount: float) -> dict[str, Any]:
    """Add cost for a role (planner/generator/tester/evaluator). File-locked."""
    if role not in VALID_ROLES:
        raise ValueError(f"Invalid role: {role}. Valid: {VALID_ROLES}")

    def _do():
        state = read_state(state_file)
        costs = {**state["costs"], role: state["costs"].get(role, 0.0) + amount}
        return write_state(state_file, {**state, "costs": costs})

    return _with_lock(state_file, _do)


def is_rate_limited(state_file: str) -> tuple[bool, int]:
    """Check if currently rate limited and return seconds to wait."""
    state = read_state(state_file)
    if state["rate_limit_until"] is None:
        return False, 0
    remaining = state["rate_limit_until"] - time.time()
    if remaining <= 0:
        return False, 0
    return True, int(remaining)


def enter_rate_limit(state_file: str, resets_at: float, current_phase: str) -> dict[str, Any]:
    """Transition to rate_limited, remembering which phase to resume."""
    return transition(
        state_file,
        "rate_limited",
        rate_limit_until=resets_at,
        rate_limit_resume_phase=current_phase,
    )


def exit_rate_limit(state_file: str) -> dict[str, Any]:
    """Resume from rate limit to the saved phase."""
    state = read_state(state_file)
    resume_phase = state.get("rate_limit_resume_phase", "generating")
    # Validate resume phase — fall back to generating if corrupted
    if resume_phase not in VALID_PHASES:
        print(
            f"[state] invalid resume phase '{resume_phase}', falling back to 'generating'",
            file=sys.stderr,
        )
        resume_phase = "generating"
    return transition(
        state_file,
        resume_phase,
        rate_limit_until=None,
        rate_limit_resume_phase=None,
    )


# CLI interface for use from bash
if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: state.py <state_file> <command> [args...]", file=sys.stderr)
        print(
            "Commands: read, write, transition <phase>, add_cost <role> <amount>", file=sys.stderr
        )
        print("          is_rate_limited, enter_rate_limit <resets_at> <phase>", file=sys.stderr)
        print("          exit_rate_limit, init", file=sys.stderr)
        sys.exit(1)

    state_file = sys.argv[1]
    command = sys.argv[2]

    if command == "init":
        result_state = write_state(state_file, default_state())
        print(json.dumps(result_state, indent=2))

    elif command == "read":
        print(json.dumps(read_state(state_file), indent=2))

    elif command == "transition":
        phase = sys.argv[3]
        extras: dict[str, Any] = {}
        for kv in sys.argv[4:]:
            if "=" not in kv:
                print(f"Error: expected key=value, got: {kv}", file=sys.stderr)
                sys.exit(1)
            k, v = kv.split("=", 1)
            with contextlib.suppress(json.JSONDecodeError, ValueError):
                v = json.loads(v)
            extras[k] = v
        result_state = transition(state_file, phase, **extras)
        print(json.dumps(result_state, indent=2))

    elif command == "add_cost":
        role = sys.argv[3]
        amount = float(sys.argv[4])
        result_state = add_cost(state_file, role, amount)
        print(json.dumps(result_state, indent=2))

    elif command == "is_rate_limited":
        limited, seconds = is_rate_limited(state_file)
        print(json.dumps({"rate_limited": limited, "wait_seconds": seconds}))

    elif command == "enter_rate_limit":
        resets_at = float(sys.argv[3])
        current_phase = sys.argv[4]
        result_state = enter_rate_limit(state_file, resets_at, current_phase)
        print(json.dumps(result_state, indent=2))

    elif command == "exit_rate_limit":
        result_state = exit_rate_limit(state_file)
        print(json.dumps(result_state, indent=2))

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)
