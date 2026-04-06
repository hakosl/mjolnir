#!/usr/bin/env bash
# Mjolnir E2E Smoke Test
#
# Runs a minimal full-stack web app project through the complete pipeline
# (planner → generator → evaluator) on the OCI instance via SSH.
#
# Prerequisites:
#   - SSH access to opc@mjolnir (Tailscale)
#   - Claude CLI authenticated on the instance
#   - mjolnir repo deployed at /home/opc/mjolnir
#
# Usage:
#   bash tests/e2e/run_e2e.sh              # run and wait
#   bash tests/e2e/run_e2e.sh --status     # check status of running e2e
#   bash tests/e2e/run_e2e.sh --cleanup    # remove e2e project from server

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="opc@100.106.150.47"
REMOTE_MJOLNIR="/home/opc/mjolnir"
REMOTE_PROJECT="${REMOTE_MJOLNIR}/workspace/e2e-smoke"
TMUX_SESSION="mjolnir-e2e"

# Timeout: max time to wait for completion (seconds)
E2E_TIMEOUT="${E2E_TIMEOUT:-600}"  # 10 minutes default

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "FAIL: $1" >&2; exit 1; }

remote() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$REMOTE" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_status() {
    echo "=== E2E Status ==="
    remote "
        if [ -f '${REMOTE_PROJECT}/state.json' ]; then
            python3 -m json.tool '${REMOTE_PROJECT}/state.json'
        else
            echo 'No state.json — not started'
        fi
        echo '---'
        tmux has-session -t '${TMUX_SESSION}' 2>/dev/null && echo 'tmux session: running' || echo 'tmux session: not running'
    "
}

cmd_cleanup() {
    echo "=== E2E Cleanup ==="
    remote "
        tmux kill-session -t '${TMUX_SESSION}' 2>/dev/null || true
        rm -rf '${REMOTE_PROJECT}'
        echo 'Cleaned up e2e-smoke project'
    "
}

cmd_run() {
    echo "=== Mjolnir E2E Smoke Test ==="
    echo "Remote: ${REMOTE}"
    echo "Timeout: ${E2E_TIMEOUT}s"
    echo ""

    # Step 1: Deploy latest code to server
    echo "--- Step 1: Deploy latest code ---"
    remote "cd '${REMOTE_MJOLNIR}' && git checkout -- . && git clean -fd --exclude=workspace/ && git pull --ff-only" || die "git pull failed"

    # Step 2: Clean up any previous e2e run
    echo "--- Step 2: Clean previous run ---"
    remote "
        tmux kill-session -t '${TMUX_SESSION}' 2>/dev/null || true
        rm -rf '${REMOTE_PROJECT}'
    "

    # Step 3: Create project from e2e fixture
    echo "--- Step 3: Create e2e project ---"
    remote "
        mkdir -p '${REMOTE_PROJECT}'
    "
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${SCRIPT_DIR}/project.toml" "${REMOTE}:${REMOTE_PROJECT}/project.toml"
    echo "Copied project.toml to server"

    # Step 4: Start mjolnir in tmux
    echo "--- Step 4: Start mjolnir ---"
    remote "
        tmux new-session -d -s '${TMUX_SESSION}' \
            'cd ${REMOTE_MJOLNIR} && MJOLNIR_PLANNING_MODE=auto bash mjolnir.sh ${REMOTE_PROJECT} 2>&1 | tee ${REMOTE_PROJECT}/e2e.log; echo EXIT_CODE=\$? >> ${REMOTE_PROJECT}/e2e.log'
    " || die "Failed to start tmux session"
    echo "Started mjolnir in tmux session '${TMUX_SESSION}'"

    # Step 5: Poll for completion
    echo "--- Step 5: Waiting for completion (timeout: ${E2E_TIMEOUT}s) ---"
    local elapsed=0
    local poll_interval=15

    while [[ "$elapsed" -lt "$E2E_TIMEOUT" ]]; do
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))

        # Check if state.json exists and read phase
        local phase
        phase="$(remote "python3 -c \"
import json, sys
try:
    with open('${REMOTE_PROJECT}/state.json') as f:
        print(json.load(f)['phase'])
except:
    print('pending')
\"" 2>/dev/null)" || phase="pending"

        case "$phase" in
            complete)
                echo ""
                echo "  [${elapsed}s] COMPLETE!"
                break
                ;;
            halted|error)
                echo ""
                echo "  [${elapsed}s] ${phase} — checking details..."
                break
                ;;
            pending)
                printf "  [%ds] waiting for start...\r" "$elapsed"
                ;;
            *)
                printf "  [%ds] phase: %s\r" "$elapsed" "$phase"
                ;;
        esac
    done

    if [[ "$elapsed" -ge "$E2E_TIMEOUT" ]]; then
        echo ""
        die "Timed out after ${E2E_TIMEOUT}s"
    fi

    # Step 6: Collect results
    echo ""
    echo "--- Step 6: Results ---"

    local state_json
    state_json="$(remote "cat '${REMOTE_PROJECT}/state.json'" 2>/dev/null)" || die "No state.json"
    echo "$state_json" | python3 -m json.tool

    local phase
    phase="$(echo "$state_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['phase'])")"
    local total_cost
    total_cost="$(echo "$state_json" | python3 -c "import json,sys; s=json.load(sys.stdin); print(round(sum(s.get('costs',{}).values()),2))")"

    echo ""
    echo "Phase: ${phase}"
    echo "Total cost: \$${total_cost}"

    # Check for eval report
    local eval_report
    eval_report="$(remote "cat '${REMOTE_PROJECT}/sprints/01/eval_report.json' 2>/dev/null")" || true

    if [[ -n "$eval_report" ]]; then
        echo ""
        echo "--- Eval Report ---"
        echo "$eval_report" | python3 -m json.tool 2>/dev/null || echo "$eval_report"
    fi

    # Step 7: Assertions
    echo ""
    echo "--- Assertions ---"
    local pass_count=0
    local fail_count=0

    # Assert: phase is complete
    if [[ "$phase" == "complete" ]]; then
        echo "  PASS: phase is complete"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL: expected phase=complete, got phase=${phase}"
        fail_count=$((fail_count + 1))
    fi

    # Assert: cost is reasonable (under $5 for haiku)
    local cost_ok
    cost_ok="$(python3 -c "print('yes' if float('${total_cost}') < 5.0 else 'no')")"
    if [[ "$cost_ok" == "yes" ]]; then
        echo "  PASS: cost \$${total_cost} < \$5.00"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL: cost \$${total_cost} >= \$5.00"
        fail_count=$((fail_count + 1))
    fi

    # Assert: eval report exists
    if [[ -n "$eval_report" ]]; then
        echo "  PASS: eval_report.json exists"
        pass_count=$((pass_count + 1))

        # Assert: all scores meet thresholds
        local scores_ok
        scores_ok="$(echo "$eval_report" | python3 -c "
import json, sys
r = json.load(sys.stdin)
s = r.get('scores', {})
thresholds = {'design_quality': 4, 'originality': 3, 'craft': 4, 'functionality': 5}
failed = [f'{k}={s.get(k,0)}<{v}' for k,v in thresholds.items() if s.get(k,0) < v]
if failed:
    print('FAIL:' + ','.join(failed))
else:
    print('PASS')
" 2>/dev/null)" || scores_ok="FAIL:parse_error"

        if [[ "$scores_ok" == "PASS" ]]; then
            echo "  PASS: all scores meet thresholds"
            pass_count=$((pass_count + 1))
        else
            echo "  FAIL: ${scores_ok}"
            fail_count=$((fail_count + 1))
        fi
    else
        echo "  FAIL: no eval_report.json"
        fail_count=$((fail_count + 1))
    fi

    # Assert: work directory has generated files
    local file_count
    file_count="$(remote "find '${REMOTE_PROJECT}/e2e-smoke' -type f -not -path '*/.git/*' 2>/dev/null | wc -l" 2>/dev/null)" || file_count="0"
    file_count="$(echo "$file_count" | tr -d ' ')"
    if [[ "$file_count" -ge 3 ]]; then
        echo "  PASS: ${file_count} files generated"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL: only ${file_count} files generated (expected >= 3)"
        fail_count=$((fail_count + 1))
    fi

    echo ""
    echo "================"
    echo "Results: ${pass_count} passed, ${fail_count} failed"

    if [[ "$fail_count" -gt 0 ]]; then
        echo ""
        echo "--- Last 30 lines of e2e.log ---"
        remote "tail -30 '${REMOTE_PROJECT}/e2e.log'" 2>/dev/null || true
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-run}" in
    --status|status)  cmd_status ;;
    --cleanup|cleanup) cmd_cleanup ;;
    --run|run|"")     cmd_run ;;
    *)                echo "Usage: $0 [run|--status|--cleanup]"; exit 1 ;;
esac
