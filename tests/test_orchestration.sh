#!/usr/bin/env bash
# Integration tests for mjolnir.sh orchestration logic:
#   - Work directory resolution (always PROJECT_DIR/PROJECT_NAME)
#   - State-based session resume behavior
#   - Sprint counting & max_sprints capping
#   - Planning mode selection
#
# Uses a mock `claude` binary to avoid real API calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MJOLNIR_SH="${SCRIPT_DIR}/mjolnir.sh"
LIB_DIR="${SCRIPT_DIR}/lib"
TEST_DIR="$(mktemp -d /tmp/mjolnir-orch-test-XXXXXXXX)"

pass_count=0
fail_count=0

pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $1 — $2"; fail_count=$((fail_count + 1)); }

cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: create a minimal project.toml
# ---------------------------------------------------------------------------
create_project() {
    local project_dir="$1"
    shift
    local max_sprints="0"
    local planning_mode="auto"
    local project_name
    project_name="$(basename "$project_dir")"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            max_sprints=*) max_sprints="${1#*=}" ;;
            mode=*) planning_mode="${1#*=}" ;;
            name=*) project_name="${1#*=}" ;;
        esac
        shift
    done

    mkdir -p "$project_dir"
    cat > "$project_dir/project.toml" <<TOML
[project]
name = "${project_name}"
description = "Test project"
goals = ["Build something"]
tech_stack = "Python"
constraints = []

[planning]
mode = "${planning_mode}"

[scoring.weights]
design_quality = 0.35
originality = 0.25
craft = 0.25
functionality = 0.15

[scoring.thresholds]
design_quality = 7
originality = 5
craft = 6
functionality = 6

[budget]
max_retries = 3
max_sprints = ${max_sprints}
budget_per_sprint = 0
TOML
}

# ---------------------------------------------------------------------------
# Helper: create a mock `claude` that emits valid JSONL and exits
# ---------------------------------------------------------------------------
setup_mock_claude() {
    local mock_dir="${TEST_DIR}/mock_bin"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/claude" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock claude — emits a minimal valid JSONL stream on stdout.
# If run with -p (headless), emit stream-json events.
# If run without -p (interactive), just exit immediately.

is_headless=false
for arg in "$@"; do
    [[ "$arg" == "-p" ]] && is_headless=true
done

if $is_headless; then
    # Read stdin (the user prompt) and discard
    cat > /dev/null
    # Emit minimal valid JSONL stream
    echo '{"type":"system","subtype":"init","session_id":"mock-sess-001","model":"mock"}'
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"Mock agent output."}]}}'
    echo '{"type":"result","cost_usd":0.01,"is_error":false,"stop_reason":"end_turn","session_id":"mock-sess-001","duration_ms":100}'
else
    # Interactive mode — just exit (simulates user doing Ctrl+D immediately)
    exit 0
fi
MOCKEOF
    chmod +x "$mock_dir/claude"
    echo "$mock_dir"
}

# ---------------------------------------------------------------------------
# Helper: read config value using the same Python logic as mjolnir.sh
# ---------------------------------------------------------------------------
read_config() {
    local toml_file="$1"
    local key_path="$2"
    local default_val="${3:-}"
    python3 - "$key_path" "$toml_file" <<'PYEOF' 2>/dev/null || echo "$default_val"
import sys
try:
    import tomllib
except ImportError:
    import tomli as tomllib

key_path = sys.argv[1]
toml_file = sys.argv[2]

with open(toml_file, "rb") as f:
    config = tomllib.load(f)

keys = key_path.split(".")
val = config
for k in keys:
    val = val[k]

if isinstance(val, list):
    print("\n".join(str(v) for v in val))
else:
    print(val)
PYEOF
}

echo "=== Orchestration tests ==="
echo "Test dir: ${TEST_DIR}"
echo ""

# ===================================================================
# WORK DIRECTORY: always PROJECT_DIR/PROJECT_NAME
# ===================================================================
echo "--- Work directory resolution ---"

# Test: work_dir is PROJECT_DIR/name from config
proj="${TEST_DIR}/my-proj"
create_project "$proj" name="my-app"
name="$(read_config "$proj/project.toml" "project.name" "unnamed")"
expected_work_dir="${proj}/${name}"
if [[ "$expected_work_dir" == "${proj}/my-app" ]]; then
    pass "work_dir_uses_project_name"
else
    fail "work_dir_uses_project_name" "expected '${proj}/my-app', got '${expected_work_dir}'"
fi

# Test: work_dir does NOT depend on directory name
proj="${TEST_DIR}/some-random-dir"
create_project "$proj" name="actual-name"
name="$(read_config "$proj/project.toml" "project.name" "unnamed")"
expected_work_dir="${proj}/${name}"
if [[ "$expected_work_dir" == "${proj}/actual-name" ]]; then
    pass "work_dir_independent_of_dir_name"
else
    fail "work_dir_independent_of_dir_name" "expected '${proj}/actual-name', got '${expected_work_dir}'"
fi

# Test: state.json lives in PROJECT_DIR, not WORK_DIR
proj="${TEST_DIR}/proj-state-loc"
create_project "$proj" name="my-code"
python3 "$LIB_DIR/state.py" "$proj/state.json" init > /dev/null

if [[ -f "$proj/state.json" ]]; then
    pass "state_in_project_dir"
else
    fail "state_in_project_dir" "state.json should be in project dir"
fi

if [[ ! -f "$proj/my-code/state.json" ]]; then
    pass "state_not_in_work_dir"
else
    fail "state_not_in_work_dir" "state.json should NOT be in work dir"
fi

# ===================================================================
# CONFIG PARSING: planning mode
# ===================================================================
echo ""
echo "--- Config: planning mode ---"

# Test: mode from config
proj="${TEST_DIR}/proj-mode-auto"
create_project "$proj" mode="auto"
mode="$(read_config "$proj/project.toml" "planning.mode" "interactive")"
if [[ "$mode" == "auto" ]]; then
    pass "planning_mode_from_config"
else
    fail "planning_mode_from_config" "expected 'auto', got '${mode}'"
fi

# Test: mode defaults to interactive when [planning] section missing
proj="${TEST_DIR}/proj-mode-default"
mkdir -p "$proj"
cat > "$proj/project.toml" <<'TOML'
[project]
name = "test"
description = "test"
goals = ["test"]
tech_stack = "Python"
constraints = []

[scoring.weights]
design_quality = 0.35
originality = 0.25
craft = 0.25
functionality = 0.15

[scoring.thresholds]
design_quality = 7
originality = 5
craft = 6
functionality = 6

[budget]
max_retries = 3
max_sprints = 0
budget_per_sprint = 0
TOML
mode="$(read_config "$proj/project.toml" "planning.mode" "interactive")"
if [[ "$mode" == "interactive" ]]; then
    pass "planning_mode_default_interactive"
else
    fail "planning_mode_default_interactive" "expected 'interactive', got '${mode}'"
fi

# Test: env var overrides config
proj="${TEST_DIR}/proj-mode-env"
create_project "$proj" mode="auto"
exported_mode="${MJOLNIR_PLANNING_MODE:-$(read_config "$proj/project.toml" "planning.mode" "interactive")}"
if [[ "$exported_mode" == "auto" ]]; then
    MJOLNIR_PLANNING_MODE="interactive"
    overridden="${MJOLNIR_PLANNING_MODE:-$(read_config "$proj/project.toml" "planning.mode" "interactive")}"
    unset MJOLNIR_PLANNING_MODE
    if [[ "$overridden" == "interactive" ]]; then
        pass "planning_mode_env_override"
    else
        fail "planning_mode_env_override" "expected 'interactive', got '${overridden}'"
    fi
else
    fail "planning_mode_env_override" "baseline should be 'auto', got '${exported_mode}'"
fi

# ===================================================================
# CONFIG PARSING: max_sprints
# ===================================================================
echo ""
echo "--- Config: max_sprints ---"

proj="${TEST_DIR}/proj-maxsprints"
create_project "$proj" max_sprints="3"
max="$(read_config "$proj/project.toml" "budget.max_sprints" "0")"
if [[ "$max" == "3" ]]; then
    pass "max_sprints_from_config"
else
    fail "max_sprints_from_config" "expected '3', got '${max}'"
fi

proj="${TEST_DIR}/proj-maxsprints-zero"
create_project "$proj" max_sprints="0"
max="$(read_config "$proj/project.toml" "budget.max_sprints" "0")"
if [[ "$max" == "0" ]]; then
    pass "max_sprints_zero_unlimited"
else
    fail "max_sprints_zero_unlimited" "expected '0', got '${max}'"
fi

# ===================================================================
# SPRINT COUNTING
# ===================================================================
echo ""
echo "--- Sprint counting ---"

sprint_dir="${TEST_DIR}/sprint-count"
mkdir -p "$sprint_dir"

# Test: count from ## Sprint N headings
cat > "$sprint_dir/plan.md" <<'MD'
# Build Plan

## Sprint 1: Setup
Do the setup.

## Sprint 2: Backend
Build the API.

## Sprint 3: Frontend
Build the UI.
MD

count="$(grep -cE '^##+ Sprint [0-9]+' "$sprint_dir/plan.md" 2>/dev/null)" || true
if [[ "$count" == "3" ]]; then
    pass "count_sprints_headings"
else
    fail "count_sprints_headings" "expected 3, got '${count}'"
fi

# Test: count from ### Sprint N subheadings
cat > "$sprint_dir/plan.md" <<'MD'
# Plan

### Sprint 1
### Sprint 2
### Sprint 3
### Sprint 4
### Sprint 5
MD

count="$(grep -cE '^##+ Sprint [0-9]+' "$sprint_dir/plan.md" 2>/dev/null)" || true
if [[ "$count" == "5" ]]; then
    pass "count_sprints_subheadings"
else
    fail "count_sprints_subheadings" "expected 5, got '${count}'"
fi

# Test: max_sprints caps the count
total=5
max_sprints=3
if [[ "$max_sprints" -gt 0 && "$total" -gt "$max_sprints" ]]; then
    total="$max_sprints"
fi
if [[ "$total" == "3" ]]; then
    pass "max_sprints_caps_count"
else
    fail "max_sprints_caps_count" "expected 3, got '${total}'"
fi

# Test: max_sprints=0 does not cap
total=8
max_sprints=0
if [[ "$max_sprints" -gt 0 && "$total" -gt "$max_sprints" ]]; then
    total="$max_sprints"
fi
if [[ "$total" == "8" ]]; then
    pass "max_sprints_zero_no_cap"
else
    fail "max_sprints_zero_no_cap" "expected 8, got '${total}'"
fi

# Test: no sprint headings falls back to pattern matching
cat > "$sprint_dir/plan.md" <<'MD'
# Plan

| Sprint | Description |
|--------|-------------|
| Sprint 1 | Setup |
| Sprint 2 | Build |
MD

count="$(grep -cE '^##+ Sprint [0-9]+' "$sprint_dir/plan.md" 2>/dev/null)" || true
if [[ "$count" -le 0 ]] 2>/dev/null || [[ -z "$count" ]]; then
    count="$(grep -ciE 'sprint [0-9]+' "$sprint_dir/plan.md" 2>/dev/null)" || true
fi
if [[ "$count" == "2" ]]; then
    pass "count_sprints_table_fallback"
else
    fail "count_sprints_table_fallback" "expected 2, got '${count}'"
fi

# ===================================================================
# STATE-BASED RESUME: mjolnir.sh exits correctly for terminal states
# ===================================================================
echo ""
echo "--- State-based resume behavior ---"

MOCK_BIN="$(setup_mock_claude)"

# Helper: run mjolnir.sh with mock claude and capture output + exit code
run_mjolnir() {
    local project_dir="$1"
    local output exit_code
    output="$(PATH="${MOCK_BIN}:${PATH}" \
        MJOLNIR_PLANNING_MODE="auto" \
        MJOLNIR_NTFY_TOPIC="" \
        MJOLNIR_MONITOR_INTERVAL="1" \
        bash "$MJOLNIR_SH" "$project_dir" 2>&1)" || exit_code=$?
    exit_code=${exit_code:-0}
    echo "EXIT:${exit_code}"
    echo "$output"
}

# Test: halted state → should exit 1 with message
proj="${TEST_DIR}/proj-halted"
create_project "$proj"
python3 "$LIB_DIR/state.py" "$proj/state.json" init > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition generating sprint=3 attempt=0 total_sprints=5 > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition halted 'last_error="Sprint 3 failed"' > /dev/null

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "EXIT:1" && echo "$output" | grep -q "halted"; then
    pass "halted_state_exits"
else
    fail "halted_state_exits" "expected exit 1 + 'halted' message. Got: $(echo "$output" | head -5)"
fi

# Verify state was NOT reset (still halted, still sprint 3)
phase="$(python3 -c "import json; print(json.load(open('$proj/state.json'))['phase'])")"
sprint="$(python3 -c "import json; print(json.load(open('$proj/state.json'))['sprint'])")"
if [[ "$phase" == "halted" && "$sprint" == "3" ]]; then
    pass "halted_state_preserved"
else
    fail "halted_state_preserved" "expected phase=halted sprint=3, got phase=${phase} sprint=${sprint}"
fi

# Test: complete state → should exit 0 with message
proj="${TEST_DIR}/proj-complete"
create_project "$proj"
python3 "$LIB_DIR/state.py" "$proj/state.json" init > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition generating sprint=1 attempt=0 total_sprints=1 > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition evaluating > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition complete > /dev/null

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "EXIT:0" && echo "$output" | grep -q "already complete"; then
    pass "complete_state_exits"
else
    fail "complete_state_exits" "expected exit 0 + 'already complete'. Got: $(echo "$output" | head -5)"
fi

# Test: idle state → should enter planning (and run mock planner)
proj="${TEST_DIR}/proj-idle"
create_project "$proj" mode="auto" name="idle-test"
# Pre-create work dir with a plan.md so planner "succeeds"
work_dir="${proj}/idle-test"
mkdir -p "$work_dir"
cat > "$work_dir/plan.md" <<'MD'
## Sprint 1: Setup
Do the setup.
MD

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "PLANNING"; then
    pass "idle_enters_planning"
else
    fail "idle_enters_planning" "expected 'PLANNING' in output. Got: $(echo "$output" | head -10)"
fi

# Test: generating state → should skip planning, go to generate loop
proj="${TEST_DIR}/proj-generating"
create_project "$proj" name="gen-test"
work_dir="${proj}/gen-test"
mkdir -p "$work_dir"
git -C "$work_dir" init -b main > /dev/null 2>&1
git -C "$work_dir" commit --allow-empty -m "init" > /dev/null 2>&1
cat > "$work_dir/plan.md" <<'MD'
## Sprint 1: Setup
Do the setup.
MD
python3 "$LIB_DIR/state.py" "$proj/state.json" init > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition generating sprint=1 attempt=0 total_sprints=1 > /dev/null

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "PLANNING"; then
    fail "generating_skips_planning" "should NOT enter planning when state=generating"
else
    if echo "$output" | grep -q "Sprint 1/1"; then
        pass "generating_skips_planning"
    else
        fail "generating_skips_planning" "expected 'Sprint 1/1'. Got: $(echo "$output" | head -10)"
    fi
fi

# Test: evaluating state → should resume as generating (re-run sprint)
proj="${TEST_DIR}/proj-evaluating"
create_project "$proj" name="eval-test"
work_dir="${proj}/eval-test"
mkdir -p "$work_dir"
git -C "$work_dir" init -b main > /dev/null 2>&1
git -C "$work_dir" commit --allow-empty -m "init" > /dev/null 2>&1
cat > "$work_dir/plan.md" <<'MD'
## Sprint 1: Setup
Do the setup.
MD
python3 "$LIB_DIR/state.py" "$proj/state.json" init > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition generating sprint=1 attempt=1 total_sprints=2 > /dev/null
python3 "$LIB_DIR/state.py" "$proj/state.json" transition evaluating > /dev/null

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "Resuming from interrupted evaluation"; then
    pass "evaluating_resumes_as_generating"
else
    fail "evaluating_resumes_as_generating" "expected resume message. Got: $(echo "$output" | head -10)"
fi

# ===================================================================
# THRESHOLD CHECK
# ===================================================================
echo ""
echo "--- Threshold checks ---"

eval_dir="${TEST_DIR}/eval-check"
mkdir -p "$eval_dir"

# Test: passing scores
cat > "$eval_dir/eval_pass.json" <<'JSON'
{"scores":{"design_quality":8,"originality":7,"craft":7,"functionality":8},"sprint":1,"attempt":1}
JSON

if python3 - "$eval_dir/eval_pass.json" "7" "5" "6" "6" <<'PYEOF' 2>/dev/null; then
import json, sys
eval_file = sys.argv[1]
thresholds = {
    "design_quality": int(sys.argv[2]),
    "originality": int(sys.argv[3]),
    "craft": int(sys.argv[4]),
    "functionality": int(sys.argv[5]),
}
with open(eval_file) as f:
    report = json.load(f)
scores = report["scores"]
passed = True
for criterion, threshold in thresholds.items():
    score = scores.get(criterion, 0)
    if score < threshold:
        passed = False
sys.exit(0 if passed else 1)
PYEOF
    pass "threshold_all_pass"
else
    fail "threshold_all_pass" "scores should pass all thresholds"
fi

# Test: failing design_quality
cat > "$eval_dir/eval_fail.json" <<'JSON'
{"scores":{"design_quality":5,"originality":7,"craft":7,"functionality":8},"sprint":1,"attempt":1}
JSON

if python3 - "$eval_dir/eval_fail.json" "7" "5" "6" "6" <<'PYEOF' 2>/dev/null; then
import json, sys
eval_file = sys.argv[1]
thresholds = {
    "design_quality": int(sys.argv[2]),
    "originality": int(sys.argv[3]),
    "craft": int(sys.argv[4]),
    "functionality": int(sys.argv[5]),
}
with open(eval_file) as f:
    report = json.load(f)
scores = report["scores"]
passed = True
for criterion, threshold in thresholds.items():
    score = scores.get(criterion, 0)
    if score < threshold:
        passed = False
sys.exit(0 if passed else 1)
PYEOF
    fail "threshold_design_fail" "design_quality=5 should fail threshold=7"
else
    pass "threshold_design_fail"
fi

# Test: exactly at threshold passes
cat > "$eval_dir/eval_exact.json" <<'JSON'
{"scores":{"design_quality":7,"originality":5,"craft":6,"functionality":6},"sprint":1,"attempt":1}
JSON

if python3 - "$eval_dir/eval_exact.json" "7" "5" "6" "6" <<'PYEOF' 2>/dev/null; then
import json, sys
eval_file = sys.argv[1]
thresholds = {
    "design_quality": int(sys.argv[2]),
    "originality": int(sys.argv[3]),
    "craft": int(sys.argv[4]),
    "functionality": int(sys.argv[5]),
}
with open(eval_file) as f:
    report = json.load(f)
scores = report["scores"]
passed = True
for criterion, threshold in thresholds.items():
    score = scores.get(criterion, 0)
    if score < threshold:
        passed = False
sys.exit(0 if passed else 1)
PYEOF
    pass "threshold_exact_passes"
else
    fail "threshold_exact_passes" "exact threshold scores should pass"
fi

# ===================================================================
# FULL FLOW: 1-sprint project with mock claude completes
# ===================================================================
echo ""
echo "--- Full flow: 1-sprint mock project ---"

proj="${TEST_DIR}/proj-full-flow"
create_project "$proj" max_sprints="1" mode="auto" name="full-flow"
work_dir="${proj}/full-flow"
mkdir -p "$work_dir"

# Mock planner output: pre-create plan.md (since mock claude won't write files)
cat > "$work_dir/plan.md" <<'MD'
## Sprint 1: Build everything
Build the whole app.
MD

# Mock evaluator output: pre-create eval_report.json
sprint_dir="${proj}/sprints/01"
mkdir -p "$sprint_dir"
cat > "$sprint_dir/eval_report.json" <<'JSON'
{"scores":{"design_quality":8,"originality":7,"craft":7,"functionality":8},"sprint":1,"attempt":1,"feedback":"Good work."}
JSON

output="$(run_mjolnir "$proj")"
if echo "$output" | grep -q "Sprint 1 PASSED" || echo "$output" | grep -q "COMPLETE"; then
    pass "full_flow_1sprint_completes"
else
    fail "full_flow_1sprint_completes" "expected completion. Got: $(echo "$output" | tail -10)"
fi

# Verify final state
phase="$(python3 -c "import json; print(json.load(open('$proj/state.json'))['phase'])")"
if [[ "$phase" == "complete" ]]; then
    pass "full_flow_state_complete"
else
    fail "full_flow_state_complete" "expected phase=complete, got '${phase}'"
fi

# Verify work_dir was created at PROJECT_DIR/PROJECT_NAME
if [[ -d "${proj}/full-flow" ]]; then
    pass "full_flow_work_dir_correct"
else
    fail "full_flow_work_dir_correct" "expected '${proj}/full-flow' to exist"
fi

# ===================================================================
# Summary
# ===================================================================
echo ""
echo "================"
echo "Results: ${pass_count} passed, ${fail_count} failed"
if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
