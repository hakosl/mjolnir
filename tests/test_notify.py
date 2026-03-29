#!/usr/bin/env python3
"""Tests for notify.py — push notification sender."""

import os
import sys
import unittest.mock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lib"))
from notify import VALID_LEVELS, notify


def test_valid_levels():
    """All expected levels are in VALID_LEVELS."""
    expected = {"info", "success", "warning", "error"}
    assert expected == VALID_LEVELS, f"Expected {expected}, got {VALID_LEVELS}"
    print("  PASS: valid_levels")


def test_invalid_level_does_not_crash():
    """Invalid level defaults to info, doesn't raise."""
    # Mock urlopen so we don't make real HTTP calls
    with unittest.mock.patch("notify.urllib.request.urlopen"):
        notify("test message", "bogus_level")  # should not raise
    print("  PASS: invalid_level_no_crash")


def test_network_failure_does_not_crash():
    """Network errors are caught and logged to stderr."""
    import urllib.error

    with unittest.mock.patch(
        "notify.urllib.request.urlopen",
        side_effect=urllib.error.URLError("connection refused"),
    ):
        notify("test message", "info")  # should not raise
    print("  PASS: network_failure_no_crash")


def test_env_vars_read_at_call_time():
    """MJOLNIR_NTFY_TOPIC is read inside notify(), not at import."""
    original = os.environ.get("MJOLNIR_NTFY_TOPIC")
    try:
        os.environ["MJOLNIR_NTFY_TOPIC"] = "custom-topic-123"
        with unittest.mock.patch("notify.urllib.request.urlopen") as mock_urlopen:
            notify("test", "info")
            call_args = mock_urlopen.call_args
            request = call_args[0][0]
            assert "custom-topic-123" in request.full_url, (
                f"Expected custom topic in URL, got: {request.full_url}"
            )
        print("  PASS: env_vars_at_call_time")
    finally:
        if original is None:
            os.environ.pop("MJOLNIR_NTFY_TOPIC", None)
        else:
            os.environ["MJOLNIR_NTFY_TOPIC"] = original


def test_content_type_header():
    """Request includes Content-Type: text/plain."""
    with unittest.mock.patch("notify.urllib.request.urlopen") as mock_urlopen:
        notify("hello", "info")
        request = mock_urlopen.call_args[0][0]
        assert request.get_header("Content-type") == "text/plain", (
            f"Expected text/plain, got: {request.get_header('Content-type')}"
        )
    print("  PASS: content_type_header")


if __name__ == "__main__":
    print("=== notify tests ===")
    test_valid_levels()
    test_invalid_level_does_not_crash()
    test_network_failure_does_not_crash()
    test_env_vars_read_at_call_time()
    test_content_type_header()
    print("\nAll notify tests passed!")
