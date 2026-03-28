#!/usr/bin/env bash
# Integration tests for the mjolnir CLI wrapper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MJOLNIR="${SCRIPT_DIR}/mjolnir"
TEST_WORKSPACE="$(mktemp -d /tmp/mjolnir-test-XXXXXX)"

export MJOLNIR_WORKSPACE="$TEST_WORKSPACE"

pass_count=0
fail_count=0

pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $1 — $2"; fail_count=$((fail_count + 1)); }

cleanup() {
    rm -rf "$TEST_WORKSPACE"
}
trap cleanup EXIT

echo "=== CLI integration tests ==="
echo "Workspace: ${TEST_WORKSPACE}"
echo ""

# --- Test: help ---
if "$MJOLNIR" help 2>&1 | grep -q "Autonomous Coding Harness"; then
    pass "help"
else
    fail "help" "help output missing expected text"
fi

# --- Test: new ---
new_output="$("$MJOLNIR" new test-project 2>&1 || true)"
if echo "$new_output" | grep -q "Created project"; then
    if [[ -f "${TEST_WORKSPACE}/test-project/project.toml" ]]; then
        pass "new"
    else
        fail "new" "project.toml not created"
    fi
else
    fail "new" "unexpected output: ${new_output}"
fi

# --- Test: new duplicate ---
dup_output="$("$MJOLNIR" new test-project 2>&1 || true)"
if echo "$dup_output" | grep -q "already exists"; then
    pass "new_duplicate"
else
    fail "new_duplicate" "expected 'already exists', got: ${dup_output}"
fi

# --- Test: status (no state) ---
if "$MJOLNIR" status test-project 2>&1 | grep -q "not started"; then
    pass "status_no_state"
else
    fail "status_no_state" "should show 'not started'"
fi

# --- Test: status (all projects) ---
if "$MJOLNIR" status 2>&1 | grep -q "test-project"; then
    pass "status_all"
else
    fail "status_all" "should list test-project"
fi

# --- Test: state.py init + status ---
python3 "${SCRIPT_DIR}/lib/state.py" "${TEST_WORKSPACE}/test-project/state.json" init > /dev/null
python3 "${SCRIPT_DIR}/lib/state.py" "${TEST_WORKSPACE}/test-project/state.json" transition generating sprint=2 attempt=1 total_sprints=5 > /dev/null
python3 "${SCRIPT_DIR}/lib/state.py" "${TEST_WORKSPACE}/test-project/state.json" add_cost generator 42.5 > /dev/null

status_output="$("$MJOLNIR" status test-project 2>&1 || true)"
if echo "$status_output" | grep -q "2/5"; then
    pass "status_with_state"
else
    fail "status_with_state" "expected '2/5' in output: ${status_output}"
fi

# --- Test: pause ---
if "$MJOLNIR" pause test-project 2>&1 | grep -q "paused"; then
    phase="$(python3 -c "import json; print(json.load(open('${TEST_WORKSPACE}/test-project/state.json'))['phase'])")"
    if [[ "$phase" == "halted" ]]; then
        pass "pause"
    else
        fail "pause" "phase should be 'halted', got '${phase}'"
    fi
else
    fail "pause" "unexpected output"
fi

# --- Test: resume (without tmux — will fail on tmux but state should reset) ---
# We just check the state gets reset, don't actually start tmux
python3 -c "
import json
with open('${TEST_WORKSPACE}/test-project/state.json') as f:
    s = json.load(f)
s['phase'] = 'halted'
with open('${TEST_WORKSPACE}/test-project/state.json', 'w') as f:
    json.dump(s, f)
"
# Resume will try to start tmux which may not work in CI, just check state change
"$MJOLNIR" resume test-project 2>&1 || true
phase="$(python3 -c "import json; print(json.load(open('${TEST_WORKSPACE}/test-project/state.json'))['phase'])")"
if [[ "$phase" == "generating" ]]; then
    pass "resume_state_reset"
else
    fail "resume_state_reset" "phase should be 'generating', got '${phase}'"
fi

# --- Test: edit (just check it doesn't crash with EDITOR=true) ---
EDITOR=true "$MJOLNIR" edit test-project 2>&1
pass "edit_no_crash"

# --- Test: unknown command ---
unk_output="$("$MJOLNIR" nonexistent 2>&1 || true)"
if echo "$unk_output" | grep -q "Unknown command"; then
    pass "unknown_command"
else
    fail "unknown_command" "expected 'Unknown command', got: ${unk_output}"
fi

# --- Summary ---
echo ""
echo "================"
echo "Results: ${pass_count} passed, ${fail_count} failed"
if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
