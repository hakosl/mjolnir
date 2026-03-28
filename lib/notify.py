#!/usr/bin/env python3
"""Push notifications via ntfy.sh for Mjolnir harness."""

from __future__ import annotations

import os
import sys
import urllib.error
import urllib.request

PRIORITY_MAP = {
    "info": "default",
    "success": "high",
    "warning": "high",
    "error": "urgent",
}

TAG_MAP = {
    "info": "gear",
    "success": "white_check_mark",
    "warning": "warning",
    "error": "rotating_light",
}

VALID_LEVELS = frozenset(PRIORITY_MAP)


def notify(message: str, level: str = "info") -> None:
    """Send push notification. Failures are logged to stderr but non-fatal."""
    if level not in VALID_LEVELS:
        print(
            f"[notify] unknown level '{level}', defaulting to 'info'",
            file=sys.stderr,
        )
        level = "info"

    topic = os.environ.get("MJOLNIR_NTFY_TOPIC", "mjolnir-harness")
    server = os.environ.get("MJOLNIR_NTFY_SERVER", "https://ntfy.sh")
    url = f"{server}/{topic}"

    headers = {
        "Title": f"Mjolnir [{level.upper()}]",
        "Priority": PRIORITY_MAP[level],
        "Tags": TAG_MAP[level],
        "Content-Type": "text/plain",
    }
    data = message.encode("utf-8")

    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5):
            pass
    except (urllib.error.URLError, OSError) as e:
        print(f"[notify] notification failed ({level}): {e}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: notify.py <message> [level]", file=sys.stderr)
        print(f"Levels: {', '.join(sorted(VALID_LEVELS))}", file=sys.stderr)
        topic = os.environ.get("MJOLNIR_NTFY_TOPIC", "mjolnir-harness")
        print(f"Topic: {topic} (set MJOLNIR_NTFY_TOPIC to change)", file=sys.stderr)
        sys.exit(1)

    msg = sys.argv[1]
    lvl = sys.argv[2] if len(sys.argv) > 2 else "info"
    notify(msg, lvl)
    topic = os.environ.get("MJOLNIR_NTFY_TOPIC", "mjolnir-harness")
    server = os.environ.get("MJOLNIR_NTFY_SERVER", "https://ntfy.sh")
    print(f"Notification sent to {server}/{topic}")
