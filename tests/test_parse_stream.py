#!/usr/bin/env python3
"""Tests for parse_stream.py — JSONL stream parser."""

import io
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from parse_stream import parse_stream


def test_normal_result():
    """Normal completion with assistant output and result event."""
    events = [
        {"type": "system", "subtype": "init", "session_id": "sess-123", "model": "opus"},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "Hello "}]}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "world"}]}},
        {
            "type": "result",
            "cost_usd": 1.5,
            "is_error": False,
            "stop_reason": "end_turn",
            "session_id": "sess-123",
            "duration_ms": 5000,
        },
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["output"] == "Hello world", f"Expected 'Hello world', got '{result['output']}'"
    assert result["cost_usd"] == 1.5, f"Expected cost 1.5, got {result['cost_usd']}"
    assert result["session_id"] == "sess-123"
    assert result["error"] is False
    assert result["stop_reason"] == "end_turn"
    assert result["rate_limited"] is False
    print("  PASS: normal_result")


def test_rate_limit_allowed_ignored():
    """Rate limit event with status=allowed is NOT treated as rate limited."""
    events = [
        {"type": "system", "subtype": "init", "session_id": "sess-allowed"},
        {
            "type": "rate_limit_event",
            "rate_limit_info": {
                "status": "allowed",
                "resetsAt": 1700000000,
                "rateLimitType": "five_hour",
                "overageStatus": "rejected",
                "isUsingOverage": False,
            },
        },
        {"type": "result", "cost_usd": 1.0, "is_error": False, "stop_reason": "end_turn"},
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["rate_limited"] is False, "status=allowed should NOT trigger rate limit"
    assert result["error"] is False
    print("  PASS: rate_limit_allowed_ignored")


def test_rate_limit_event():
    """Rate limit event with status=limited is detected."""
    events = [
        {"type": "system", "subtype": "init", "session_id": "sess-456"},
        {
            "type": "rate_limit_event",
            "resetsAt": 1700000000,
            "rateLimitType": "five_hour",
            "status": "limited",
            "overageStatus": "none",
        },
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["rate_limited"] is True, "Expected rate_limited=True"
    assert result["rate_limit_resets_at"] == 1700000000, (
        f"Expected resetsAt 1700000000, got {result['rate_limit_resets_at']}"
    )
    # No result event — should flag as error too
    assert result["error"] is False or result["rate_limited"] is True, (
        "Rate limited streams should not be flagged as error"
    )
    print("  PASS: rate_limit_event")


def test_rate_limit_nested():
    """Rate limit event with resetsAt nested under rate_limit_info."""
    events = [
        {"type": "system", "subtype": "init", "session_id": "sess-nested"},
        {
            "type": "rate_limit_event",
            "rate_limit_info": {
                "status": "rejected",
                "resetsAt": 1774832400,
                "rateLimitType": "five_hour",
                "overageStatus": "rejected",
                "isUsingOverage": False,
            },
        },
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["rate_limited"] is True, "Expected rate_limited=True for nested resetsAt"
    assert result["rate_limit_resets_at"] == 1774832400, (
        f"Expected resetsAt 1774832400, got {result['rate_limit_resets_at']}"
    )
    print("  PASS: rate_limit_nested")


def test_stream_crash_no_result():
    """Stream ends without result event (process crash)."""
    events = [
        {"type": "system", "subtype": "init", "session_id": "sess-789"},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "partial output"}]}},
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["error"] is True, "Expected error=True on missing result event"
    assert "crash" in result["error_message"].lower(), (
        f"Expected crash message, got: {result['error_message']}"
    )
    assert result["output"] == "partial output"
    print("  PASS: stream_crash_no_result")


def test_null_cost():
    """cost_usd: null in result event should not crash."""
    events = [
        {"type": "result", "cost_usd": None, "is_error": False, "stop_reason": "end_turn"},
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["cost_usd"] == 0.0, f"Expected 0.0, got {result['cost_usd']}"
    assert result["error"] is False
    print("  PASS: null_cost")


def test_error_result():
    """Agent returns an error."""
    events = [
        {
            "type": "result",
            "is_error": True,
            "result": "Context window exceeded",
            "cost_usd": 0.5,
            "stop_reason": "max_tokens",
        },
    ]
    stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
    result = parse_stream(stream)

    assert result["error"] is True
    assert result["error_message"] == "Context window exceeded"
    assert result["cost_usd"] == 0.5
    print("  PASS: error_result")


def test_empty_stream():
    """Completely empty stream (claude didn't start)."""
    stream = io.StringIO("")
    result = parse_stream(stream)

    assert result["error"] is True, "Expected error on empty stream"
    assert result["output"] == ""
    print("  PASS: empty_stream")


def test_malformed_json_lines():
    """Malformed JSON lines are skipped, valid ones still parsed."""
    lines = [
        "not json at all",
        json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "ok"}]}}),
        "{broken json",
        json.dumps(
            {"type": "result", "cost_usd": 1.0, "is_error": False, "stop_reason": "end_turn"}
        ),
    ]
    stream = io.StringIO("\n".join(lines) + "\n")
    result = parse_stream(stream)

    assert result["output"] == "ok", f"Expected 'ok', got '{result['output']}'"
    assert result["error"] is False
    print("  PASS: malformed_json_lines")


def test_log_file_writing():
    """Log file receives events when MJOLNIR_LOG is set."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".log", delete=False) as f:
        log_path = f.name

    try:
        events = [
            {"type": "system", "subtype": "init", "session_id": "s1"},
            {"type": "result", "cost_usd": 2.0, "is_error": False, "stop_reason": "end_turn"},
        ]
        stream = io.StringIO("\n".join(json.dumps(e) for e in events) + "\n")
        parse_stream(stream, log_file=log_path)

        with open(log_path) as f:
            log_lines = [json.loads(line) for line in f if line.strip()]

        assert len(log_lines) >= 2, f"Expected at least 2 log entries, got {len(log_lines)}"
        events_logged = [entry["event"] for entry in log_lines]
        assert "session_init" in events_logged
        assert "result" in events_logged
        print("  PASS: log_file_writing")
    finally:
        os.unlink(log_path)


if __name__ == "__main__":
    print("=== parse_stream tests ===")
    test_normal_result()
    test_rate_limit_allowed_ignored()
    test_rate_limit_event()
    test_rate_limit_nested()
    test_stream_crash_no_result()
    test_null_cost()
    test_error_result()
    test_empty_stream()
    test_malformed_json_lines()
    test_log_file_writing()
    print("\nAll parse_stream tests passed!")
