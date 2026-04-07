#!/usr/bin/env python3
"""Tests for state.py — atomic state machine."""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
import contextlib

from state import (
    add_cost,
    default_state,
    enter_rate_limit,
    exit_rate_limit,
    is_rate_limited,
    read_state,
    transition,
    write_state,
)


def make_temp_state():
    """Create a temp file path for state."""
    fd, path = tempfile.mkstemp(suffix=".json")
    os.close(fd)
    os.unlink(path)  # start clean
    return path


def cleanup(path):
    """Remove state file and associated lock/tmp files."""
    for suffix in ("", ".lock", ".tmp"):
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path + suffix)


def test_default_state():
    """Default state has correct initial values."""
    state = default_state()
    assert state["phase"] == "idle"
    assert state["sprint"] == 0
    assert state["costs"]["planner"] == 0.0
    assert state["costs"]["tester"] == 0.0
    print("  PASS: default_state")


def test_write_and_read():
    """Write state and read it back."""
    path = make_temp_state()
    try:
        state = default_state()
        written = write_state(path, state)
        read_back = read_state(path)
        assert read_back["phase"] == "idle"
        assert read_back["updated_at"] == written["updated_at"]
        print("  PASS: write_and_read")
    finally:
        cleanup(path)


def test_transition():
    """Phase transitions update state correctly."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        state = transition(path, "planning")
        assert state["phase"] == "planning"

        state = transition(path, "generating", sprint=1, attempt=0, total_sprints=5)
        assert state["phase"] == "generating"
        assert state["sprint"] == 1
        assert state["total_sprints"] == 5
        print("  PASS: transition")
    finally:
        cleanup(path)


def test_invalid_transition():
    """Invalid phase raises ValueError."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        try:
            transition(path, "nonexistent_phase")
            raise AssertionError("Should have raised ValueError")
        except ValueError:
            pass
        print("  PASS: invalid_transition")
    finally:
        cleanup(path)


def test_add_cost():
    """Cost accumulation works correctly."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        state = add_cost(path, "generator", 42.5)
        assert state["costs"]["generator"] == 42.5

        state = add_cost(path, "generator", 10.0)
        assert state["costs"]["generator"] == 52.5

        state = add_cost(path, "evaluator", 5.0)
        assert state["costs"]["evaluator"] == 5.0
        assert state["costs"]["generator"] == 52.5  # unchanged
        print("  PASS: add_cost")
    finally:
        cleanup(path)


def test_rate_limit_cycle():
    """Enter rate limit, check, and exit."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        transition(path, "generating")

        # Enter rate limit
        future = time.time() + 3600
        state = enter_rate_limit(path, future, "generating")
        assert state["phase"] == "rate_limited"
        assert state["rate_limit_resume_phase"] == "generating"

        # Check rate limited
        limited, secs = is_rate_limited(path)
        assert limited is True
        assert secs > 3500  # should be close to 3600

        # Exit rate limit
        state = exit_rate_limit(path)
        assert state["phase"] == "generating"
        assert state["rate_limit_until"] is None

        # Check not rate limited
        limited, secs = is_rate_limited(path)
        assert limited is False
        print("  PASS: rate_limit_cycle")
    finally:
        cleanup(path)


def test_exit_rate_limit_invalid_resume_phase():
    """Exit rate limit with corrupted resume phase falls back to generating."""
    path = make_temp_state()
    try:
        write_state(
            path,
            {
                **default_state(),
                "phase": "rate_limited",
                "rate_limit_resume_phase": "totally_bogus",
                "rate_limit_until": time.time() - 100,
            },
        )
        state = exit_rate_limit(path)
        assert state["phase"] == "generating", f"Expected 'generating', got '{state['phase']}'"
        print("  PASS: exit_rate_limit_invalid_resume")
    finally:
        cleanup(path)


def test_stale_tmp_cleanup():
    """Stale .tmp file from a crash is cleaned up on read."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        # Simulate a crash-left .tmp file
        tmp_path = path + ".tmp"
        with open(tmp_path, "w") as f:
            f.write("{corrupted")

        # Read should succeed and clean up .tmp
        state = read_state(path)
        assert state["phase"] == "idle"
        assert not os.path.exists(tmp_path), ".tmp file should have been cleaned up"
        print("  PASS: stale_tmp_cleanup")
    finally:
        cleanup(path)


def test_corrupt_state_file():
    """Corrupt JSON in state file raises RuntimeError."""
    path = make_temp_state()
    try:
        with open(path, "w") as f:
            f.write("{broken json")
        try:
            read_state(path)
            raise AssertionError("Should have raised RuntimeError")
        except RuntimeError as e:
            assert "corrupted" in str(e).lower()
        print("  PASS: corrupt_state_file")
    finally:
        cleanup(path)


def test_missing_state_file():
    """Missing state file returns default state."""
    path = "/tmp/nonexistent-mjolnir-test-state.json"
    state = read_state(path)
    assert state["phase"] == "idle"
    print("  PASS: missing_state_file")


def test_testing_phase():
    """Testing phase transitions work in the generate→test→evaluate flow."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        transition(path, "generating", sprint=1, attempt=1, total_sprints=3)

        state = transition(path, "testing")
        assert state["phase"] == "testing"
        assert state["sprint"] == 1

        state = transition(path, "evaluating")
        assert state["phase"] == "evaluating"

        # Tester cost tracking
        state = add_cost(path, "tester", 3.5)
        assert state["costs"]["tester"] == 3.5
        print("  PASS: testing_phase")
    finally:
        cleanup(path)


def test_crash_recovery_simulation():
    """Simulate crash mid-sprint: state persists, can resume."""
    path = make_temp_state()
    try:
        write_state(path, default_state())
        transition(path, "planning")
        transition(path, "generating", sprint=2, attempt=1, total_sprints=5)
        transition(path, "evaluating")

        # "Crash" — just read state back as if restarting
        state = read_state(path)
        assert state["phase"] == "evaluating"
        assert state["sprint"] == 2
        assert state["attempt"] == 1
        assert state["total_sprints"] == 5

        # Resume by transitioning back to generating
        state = transition(path, "generating")
        assert state["phase"] == "generating"
        assert state["sprint"] == 2  # same sprint
        print("  PASS: crash_recovery_simulation")
    finally:
        cleanup(path)


if __name__ == "__main__":
    print("=== state tests ===")
    test_default_state()
    test_write_and_read()
    test_transition()
    test_invalid_transition()
    test_add_cost()
    test_rate_limit_cycle()
    test_exit_rate_limit_invalid_resume_phase()
    test_stale_tmp_cleanup()
    test_corrupt_state_file()
    test_missing_state_file()
    test_testing_phase()
    test_crash_recovery_simulation()
    print("\nAll state tests passed!")
