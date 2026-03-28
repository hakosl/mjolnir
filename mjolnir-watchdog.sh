#!/usr/bin/env bash
# Mjolnir Watchdog — Cron job that restarts crashed sessions.
# Install: */5 * * * * /path/to/mjolnir-watchdog.sh /path/to/workspace/project
#
# Checks if the tmux session is alive. If dead and state is non-terminal,
# restarts mjolnir.sh. Respects rate_limit_until (won't restart early).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    echo "Usage: mjolnir-watchdog.sh <project-dir>" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$1" && pwd)"
STATE_FILE="${PROJECT_DIR}/state.json"
# Use md5 hash of full path to avoid collisions between same-named dirs
SESSION_NAME="mjolnir-$(echo "$PROJECT_DIR" | md5sum 2>/dev/null | cut -c1-8 || echo "$PROJECT_DIR" | md5 -q 2>/dev/null | cut -c1-8 || basename "$PROJECT_DIR")"

# No state file = nothing to watch
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Read current phase (safe — no shell interpolation into Python)
PHASE="$(python3 - "$STATE_FILE" <<'PYEOF' 2>/dev/null || echo "unknown"
import json, sys
with open(sys.argv[1]) as f:
    print(json.load(f)["phase"])
PYEOF
)"

# Terminal states — nothing to do
if [[ "$PHASE" == "complete" || "$PHASE" == "halted" || "$PHASE" == "idle" ]]; then
    exit 0
fi

# Check if tmux session is already running
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    exit 0  # Still alive, nothing to do
fi

# If rate limited, check if we should wait
if [[ "$PHASE" == "rate_limited" ]]; then
    RATE_UNTIL="$(python3 - "$STATE_FILE" <<'PYEOF' 2>/dev/null || echo "0"
import json, sys
with open(sys.argv[1]) as f:
    print(int(json.load(f).get("rate_limit_until", 0)))
PYEOF
)"
    NOW="$(date +%s)"
    if [[ "$RATE_UNTIL" -gt "$NOW" ]]; then
        REMAINING=$(( (RATE_UNTIL - NOW + 59) / 60 ))
        echo "Still rate limited. ${REMAINING}m remaining. Not restarting."
        exit 0
    fi
fi

# Session is dead but state is non-terminal — restart
echo "Restarting mjolnir for $(basename "$PROJECT_DIR") (phase: ${PHASE})"

tmux new-session -d -s "$SESSION_NAME" \
    "bash '${SCRIPT_DIR}/mjolnir.sh' '${PROJECT_DIR}' 2>&1 | tee -a '${PROJECT_DIR}/mjolnir-tmux.log'"

# Notify
python3 "${SCRIPT_DIR}/lib/notify.py" \
    "Watchdog restarted mjolnir (phase: ${PHASE})" \
    "warning" 2>/dev/null || true
