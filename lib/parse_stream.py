#!/usr/bin/env python3
"""JSONL stream parser for Claude Code `--output-format stream-json --verbose`.

Reads JSONL from stdin (piped from claude -p), detects rate limit events,
errors, costs, and extracts the final result. Designed to be called from
the orchestrator shell script.

Output: Single JSON object to stdout with the parsed result.
Side effects: Writes events to a log file if MJOLNIR_LOG env var is set.
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time
from typing import IO, Any


def parse_stream(
    input_stream: IO[str],
    log_file: str | None = None,
) -> dict[str, Any]:
    """Parse JSONL stream from claude -p and return structured result."""
    result: dict[str, Any] = {
        "output": "",
        "cost_usd": 0.0,
        "session_id": None,
        "rate_limited": False,
        "rate_limit_resets_at": None,
        "error": False,
        "error_message": None,
        "stop_reason": None,
        "duration_ms": 0,
    }

    output_parts: list[str] = []
    got_result_event = False
    start_time = time.time()

    for line in input_stream:
        line = line.strip()
        if not line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            _log_event(log_file, "parse_error", {"raw_line": line[:200]})
            continue

        event_type = event.get("type", "")

        if event_type == "system" and event.get("subtype") == "init":
            result["session_id"] = event.get("session_id")
            _log_event(
                log_file,
                "session_init",
                {
                    "session_id": event.get("session_id"),
                    "model": event.get("model"),
                },
            )

        elif event_type == "assistant":
            message = event.get("message", {})
            for block in message.get("content", []):
                if block.get("type") == "text":
                    output_parts.append(block.get("text", ""))

        elif event_type == "rate_limit_event":
            # Ignore informational rate_limit_events with null resetsAt
            # (emitted at session start as a status check, not an actual limit)
            resets_at = event.get("resetsAt")
            if resets_at is not None:
                result["rate_limited"] = True
                result["rate_limit_resets_at"] = resets_at
                _log_event(
                    log_file,
                    "rate_limit",
                    {
                        "resets_at": resets_at,
                        "rate_limit_type": event.get("rateLimitType"),
                        "status": event.get("status"),
                        "overage_status": event.get("overageStatus"),
                    },
                )

        elif event_type == "result":
            got_result_event = True
            # Guard against null cost values
            result["cost_usd"] = float(event.get("cost_usd") or event.get("total_cost_usd") or 0.0)
            result["error"] = event.get("is_error", False)
            result["stop_reason"] = event.get("stop_reason")
            result["session_id"] = event.get("session_id", result["session_id"])
            result["duration_ms"] = event.get("duration_ms", 0)

            if event.get("is_error"):
                result["error_message"] = event.get("result", "Unknown error")

            _log_event(
                log_file,
                "result",
                {
                    "cost_usd": result["cost_usd"],
                    "is_error": result["error"],
                    "stop_reason": result["stop_reason"],
                    "duration_ms": result["duration_ms"],
                },
            )

    # Join collected output parts (avoids O(n^2) string concatenation)
    result["output"] = "".join(output_parts)

    # If no output from assistant events, use result text
    if not result["output"] and got_result_event and not result["error"]:
        # Re-read isn't needed; the result event text isn't captured separately.
        # This is a fallback for simple outputs.
        pass

    # Detect stream ending without a result event (process crash)
    if not got_result_event and not result["rate_limited"]:
        result["error"] = True
        result["error_message"] = "Stream ended without a result event (process crash?)"
        _log_event(
            log_file,
            "stream_incomplete",
            {
                "had_output": bool(result["output"]),
            },
        )

    result["wall_time_s"] = round(time.time() - start_time, 1)
    return result


def _log_event(
    log_file: str | None,
    event_type: str,
    details: dict[str, Any],
) -> None:
    """Append structured log event if log file is configured."""
    if log_file is None:
        return
    entry = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "event": event_type,
        **details,
    }
    try:
        with open(log_file, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError as e:
        print(f"[mjolnir] log write failed: {e}", file=sys.stderr)


def stream_events(input_stream: IO[str], log_file: str | None = None):
    """Yield parsed events as they arrive — enables real-time rate limit detection.

    Yields dicts with 'type' key: 'init', 'rate_limit', 'result', 'done'.
    The final 'done' event contains the full aggregated result.
    """
    result: dict[str, Any] = {
        "output": "",
        "cost_usd": 0.0,
        "session_id": None,
        "rate_limited": False,
        "rate_limit_resets_at": None,
        "error": False,
        "error_message": None,
        "stop_reason": None,
        "duration_ms": 0,
    }

    output_parts: list[str] = []
    got_result_event = False
    start_time = time.time()

    for line in input_stream:
        line = line.strip()
        if not line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            _log_event(log_file, "parse_error", {"raw_line": line[:200]})
            continue

        event_type = event.get("type", "")

        if event_type == "system" and event.get("subtype") == "init":
            result["session_id"] = event.get("session_id")
            _log_event(
                log_file,
                "session_init",
                {
                    "session_id": event.get("session_id"),
                    "model": event.get("model"),
                },
            )
            yield {"type": "init", "session_id": event.get("session_id")}

        elif event_type == "assistant":
            message = event.get("message", {})
            for block in message.get("content", []):
                if block.get("type") == "text":
                    output_parts.append(block.get("text", ""))

        elif event_type == "rate_limit_event":
            resets_at = event.get("resetsAt")
            # Ignore informational events with null resetsAt (startup status check)
            if resets_at is None:
                continue
            result["rate_limited"] = True
            result["rate_limit_resets_at"] = resets_at
            _log_event(
                log_file,
                "rate_limit",
                {
                    "resets_at": resets_at,
                    "rate_limit_type": event.get("rateLimitType"),
                },
            )
            # Yield immediately so orchestrator can act
            yield {
                "type": "rate_limit",
                "resets_at": resets_at,
                "rate_limit_type": event.get("rateLimitType"),
            }

        elif event_type == "result":
            got_result_event = True
            result["cost_usd"] = float(event.get("cost_usd") or event.get("total_cost_usd") or 0.0)
            result["error"] = event.get("is_error", False)
            result["stop_reason"] = event.get("stop_reason")
            result["session_id"] = event.get("session_id", result["session_id"])
            result["duration_ms"] = event.get("duration_ms", 0)
            if event.get("is_error"):
                result["error_message"] = event.get("result", "Unknown error")
            _log_event(
                log_file,
                "result",
                {
                    "cost_usd": result["cost_usd"],
                    "is_error": result["error"],
                    "stop_reason": result["stop_reason"],
                },
            )

    result["output"] = "".join(output_parts)
    if not got_result_event and not result["rate_limited"]:
        result["error"] = True
        result["error_message"] = "Stream ended without a result event (process crash?)"
    result["wall_time_s"] = round(time.time() - start_time, 1)
    yield {"type": "done", "result": result}


if __name__ == "__main__":
    log_path = os.environ.get("MJOLNIR_LOG")

    # Check if --stream mode (write events as they arrive)
    if "--stream" in sys.argv:
        for event in stream_events(sys.stdin, log_file=log_path):
            print(json.dumps(event), flush=True)
        sys.exit(0)

    # Default: batch mode (original behavior)
    result = parse_stream(sys.stdin, log_file=log_path)
    print(json.dumps(result, indent=2))
    sys.exit(1 if result["error"] else 0)
