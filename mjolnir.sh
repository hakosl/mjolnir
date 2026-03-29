#!/usr/bin/env bash
# Mjolnir — Autonomous coding harness with generator-evaluator pattern.
# Usage: mjolnir.sh <workspace/project-dir>
#
# The project dir must contain a project.toml file.
# State is persisted to state.json for crash recovery.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
PROMPTS_DIR="${SCRIPT_DIR}/prompts"

# Max rate limit retries before giving up (prevents infinite recursion)
MAX_RATE_LIMIT_RETRIES=5

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: mjolnir.sh <project-dir>" >&2
    echo "  project-dir must contain project.toml" >&2
    exit 1
fi

PROJECT_DIR="$(cd "$1" && pwd)"
STATE_FILE="${PROJECT_DIR}/state.json"
LOG_FILE="${PROJECT_DIR}/mjolnir.log"

if [[ ! -f "${PROJECT_DIR}/project.toml" ]]; then
    echo "Error: ${PROJECT_DIR}/project.toml not found" >&2
    exit 1
fi

export MJOLNIR_LOG="${LOG_FILE}"

# ---------------------------------------------------------------------------
# Cleanup on exit — reap background notify processes
# ---------------------------------------------------------------------------
cleanup() {
    wait 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Config parsing (reads project.toml via python — safe, no interpolation)
# ---------------------------------------------------------------------------
read_config() {
    local key_path="$1"
    local default_val="$2"
    python3 - "$key_path" "${PROJECT_DIR}/project.toml" <<'PYEOF' 2>/dev/null || echo "$default_val"
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

PROJECT_NAME="$(read_config 'project.name' 'unnamed')"
MAX_RETRIES="$(read_config 'budget.max_retries' '3')"
BUDGET_PER_SPRINT="$(read_config 'budget.budget_per_sprint' '80')"
MAX_SPRINTS="$(read_config 'budget.max_sprints' '0')"

# Output directory — where generated code lives (separate git repo)
OUTPUT_DIR_RAW="$(read_config 'project.output_dir' 'src')"

# Resolve output_dir: absolute paths used as-is, relative paths resolved from PROJECT_DIR
if [[ "$OUTPUT_DIR_RAW" = /* ]]; then
    WORK_DIR="$OUTPUT_DIR_RAW"
else
    WORK_DIR="${PROJECT_DIR}/${OUTPUT_DIR_RAW}"
fi

# Planning mode — env var override takes precedence over config
PLANNING_MODE="${MJOLNIR_PLANNING_MODE:-$(read_config 'planning.mode' 'interactive')}"

# Thresholds
THRESH_DESIGN="$(read_config 'scoring.thresholds.design_quality' '7')"
THRESH_ORIGINALITY="$(read_config 'scoring.thresholds.originality' '5')"
THRESH_CRAFT="$(read_config 'scoring.thresholds.craft' '6')"
THRESH_FUNCTIONALITY="$(read_config 'scoring.thresholds.functionality' '6')"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_event() {
    local event="$1"
    shift
    python3 - "$event" "${LOG_FILE}" "$@" <<'PYEOF'
import json, time, sys
entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": sys.argv[1]}
for arg in sys.argv[3:]:
    if "=" not in arg:
        continue
    k, v = arg.split("=", 1)
    try:
        v = json.loads(v)
    except (json.JSONDecodeError, ValueError):
        pass
    entry[k] = v
with open(sys.argv[2], "a") as f:
    f.write(json.dumps(entry) + "\n")
PYEOF
}

notify() {
    local message="$1"
    local level="${2:-info}"
    python3 "${LIB_DIR}/notify.py" "$message" "$level" 2>/dev/null &
}

state_cmd() {
    python3 "${LIB_DIR}/state.py" "${STATE_FILE}" "$@"
}

# Safe JSON field reader — passes file path as argument, not interpolation
json_field() {
    local file="$1"
    local field="$2"
    local default="${3:-}"
    python3 - "$file" "$field" "$default" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    val = data.get(sys.argv[2])
    print(sys.argv[3] if val is None else val)
except (KeyError, json.JSONDecodeError, FileNotFoundError):
    print(sys.argv[3])
PYEOF
}

get_phase() {
    json_field "${STATE_FILE}" "phase" "idle"
}

get_sprint() {
    json_field "${STATE_FILE}" "sprint" "0"
}

get_total_sprints() {
    json_field "${STATE_FILE}" "total_sprints" "0"
}

get_attempt() {
    json_field "${STATE_FILE}" "attempt" "0"
}

# ---------------------------------------------------------------------------
# Rate limit handling
# ---------------------------------------------------------------------------
check_and_wait_rate_limit() {
    local rl_info
    rl_info="$(state_cmd is_rate_limited)"
    local is_limited
    is_limited="$(echo "$rl_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['rate_limited'])")"

    if [[ "$is_limited" == "True" ]]; then
        local wait_secs
        wait_secs="$(echo "$rl_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['wait_seconds'])")"
        local wait_mins=$(( (wait_secs + 59) / 60 ))
        log_event "rate_limit_wait" "seconds=${wait_secs}"
        notify "Rate limited. Resuming in ${wait_mins}m" "warning"
        echo "Rate limited. Waiting ${wait_mins} minutes..."
        sleep "$((wait_secs + 60))"  # +60s buffer
        state_cmd exit_rate_limit > /dev/null
        notify "Rate limit cleared. Resuming." "info"
    fi
}

# ---------------------------------------------------------------------------
# Agent invocation
# ---------------------------------------------------------------------------
run_agent() {
    local role="$1"
    local system_prompt_file="$2"
    local user_prompt="$3"
    local budget="$4"
    local work_dir="${5:-${WORK_DIR}}"
    local rate_limit_retries="${6:-0}"

    # Check rate limit before starting
    check_and_wait_rate_limit

    local result_file
    result_file="$(mktemp /tmp/mjolnir-result-XXXXXXXX)"

    # Ensure temp file is cleaned up on any exit path
    # shellcheck disable=SC2064  # Intentional early expansion of $result_file
    trap "rm -f '$result_file'" RETURN

    echo "Running ${role} agent (budget: \$${budget})..."
    log_event "agent_start" "role=${role}" "budget=${budget}"

    # Invoke claude -p with stream-json, pipe through streaming parser.
    # The streaming parser writes JSONL events to result_file as they arrive.
    # We monitor the file for rate_limit events and kill claude if needed.
    # Tee the raw JSONL stream to a debug file for troubleshooting
    local raw_stream_file="${PROJECT_DIR}/.raw_stream_${role}.jsonl"
    echo "$user_prompt" | claude -p \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions \
        --system-prompt "$(cat "${system_prompt_file}")" \
        -d "$work_dir" \
        2>/dev/null | tee "$raw_stream_file" | python3 "${LIB_DIR}/parse_stream.py" --stream > "$result_file" &
    local pipeline_pid=$!

    # Monitor: check for rate_limit or done events every 10s, show progress
    local elapsed=0
    while kill -0 "$pipeline_pid" 2>/dev/null; do
        sleep 10
        elapsed=$((elapsed + 10))
        # Check if we got a "done" event or a result with end_turn (agent completed)
        if grep -q '"type": "done"' "$result_file" 2>/dev/null; then
            break
        fi
        # Also check for result event in the raw stream (claude may keep running after result)
        if grep -q '"stop_reason": "end_turn"' "$raw_stream_file" 2>/dev/null; then
            echo "Agent completed (detected end_turn in stream) — killing pipeline"
            kill "$pipeline_pid" 2>/dev/null
            wait "$pipeline_pid" 2>/dev/null || true
            break
        fi
        # Check if we got a rate_limit event (agent paused by API)
        if grep -q '"type": "rate_limit"' "$result_file" 2>/dev/null; then
            echo "Rate limit detected mid-stream — killing claude process"
            kill "$pipeline_pid" 2>/dev/null
            wait "$pipeline_pid" 2>/dev/null || true
            break
        fi
        # Progress indicator every 30s
        if (( elapsed % 30 == 0 )); then
            local event_count
            event_count="$(wc -l < "$result_file" 2>/dev/null || echo 0)"
            local file_count
            file_count="$(find "$work_dir" -type f -not -path "*/.git/*" 2>/dev/null | wc -l | tr -d ' ')"
            echo "  [${elapsed}s] ${role} working... (${event_count} events, ${file_count} files in work dir)"
        fi
    done
    wait "$pipeline_pid" 2>/dev/null || true

    # Check if result file has content
    if [[ ! -s "$result_file" ]]; then
        echo "Agent ${role} failed: no output from claude pipeline"
        log_event "agent_pipeline_fail" "role=${role}"
        return 1
    fi

    # Parse the streaming events from the result file.
    # The "done" line has the aggregated result; if missing, check for rate_limit.
    local done_line
    done_line="$(grep '"type": "done"' "$result_file" 2>/dev/null | tail -1)"
    if [[ -n "$done_line" ]]; then
        echo "$done_line" | python3 -c "import json,sys; e=json.load(sys.stdin); print(json.dumps(e['result'], indent=2))" > "$result_file"
    else
        local rl_line
        rl_line="$(grep '"type": "rate_limit"' "$result_file" 2>/dev/null | tail -1)"
        if [[ -n "$rl_line" ]]; then
            local resets_at
            resets_at="$(echo "$rl_line" | python3 -c "import json,sys; print(json.load(sys.stdin).get('resets_at') or 0)")"
            if [[ "$resets_at" == "None" || "$resets_at" == "null" || -z "$resets_at" ]]; then
                resets_at="0"
            fi
            python3 -c "import json; print(json.dumps({'output':'','cost_usd':0,'rate_limited':True,'rate_limit_resets_at':$resets_at,'error':False,'error_message':None,'stop_reason':None,'duration_ms':0}))" > "$result_file"
        else
            echo "Agent ${role} failed: no result or rate limit event"
            log_event "agent_pipeline_fail" "role=${role}"
            return 1
        fi
    fi

    # Parse result safely
    local agent_error
    agent_error="$(json_field "$result_file" "error" "False")"
    local cost
    cost="$(json_field "$result_file" "cost_usd" "0")"
    local stop_reason
    stop_reason="$(json_field "$result_file" "stop_reason" "")"
    local rate_limited
    rate_limited="$(json_field "$result_file" "rate_limited" "False")"

    # Track cost regardless of outcome
    if [[ "$cost" != "0" && "$cost" != "0.0" ]]; then
        state_cmd add_cost "$role" "$cost" > /dev/null
    fi

    # If the agent completed successfully, accept the result even if a rate limit
    # event was also emitted (rate limit can arrive after completion)
    if [[ "$stop_reason" == "end_turn" && "$agent_error" != "True" ]]; then
        log_event "agent_done" "role=${role}" "cost=${cost}" "error=false"

        # If rate limited, note it for the NEXT agent invocation
        if [[ "$rate_limited" == "True" ]]; then
            local resets_at
            resets_at="$(json_field "$result_file" "rate_limit_resets_at" "0")"
            if [[ "$resets_at" == "None" || "$resets_at" == "null" || -z "$resets_at" ]]; then
                resets_at="0"
            fi
            state_cmd enter_rate_limit "$resets_at" "$(get_phase)" > /dev/null
            log_event "rate_limit_after_success" "role=${role}" "resets_at=${resets_at}"
            echo "Agent ${role} completed (cost: \$${cost}) — rate limited for next run"
        else
            echo "Agent ${role} completed (cost: \$${cost})"
        fi
        # Save agent output for fallback use (e.g., planner text extraction)
        local output_text
        output_text="$(json_field "$result_file" "output" "")"
        if [[ -n "$output_text" ]]; then
            echo "$output_text" > "${PROJECT_DIR}/.last_agent_output"
        fi
        return 0
    fi

    # Agent did NOT complete — check if rate limited mid-run
    if [[ "$rate_limited" == "True" ]]; then
        local resets_at
        resets_at="$(json_field "$result_file" "rate_limit_resets_at" "0")"
        if [[ "$resets_at" == "None" || "$resets_at" == "null" || -z "$resets_at" ]]; then
            resets_at="0"
        fi
        state_cmd enter_rate_limit "$resets_at" "$(get_phase)" > /dev/null
        log_event "rate_limit_hit" "role=${role}" "resets_at=${resets_at}"
        notify "Rate limited during ${role}. Will resume at reset." "warning"

        # Guard against infinite recursion
        rate_limit_retries=$((rate_limit_retries + 1))
        if [[ "$rate_limit_retries" -ge "$MAX_RATE_LIMIT_RETRIES" ]]; then
            echo "Agent ${role}: rate limited ${MAX_RATE_LIMIT_RETRIES} times. Halting."
            log_event "rate_limit_exhausted" "role=${role}" "retries=${rate_limit_retries}"
            notify "Rate limit retries exhausted for ${role}. Halting." "error"
            return 1
        fi

        # Wait and retry (with retry counter)
        check_and_wait_rate_limit
        run_agent "$role" "$system_prompt_file" "$user_prompt" "$budget" "$work_dir" "$rate_limit_retries"
        return $?
    fi

    # Agent errored without rate limit
    log_event "agent_done" "role=${role}" "cost=${cost}" "error=${agent_error}"

    if [[ "$agent_error" == "True" ]]; then
        local error_msg
        error_msg="$(json_field "$result_file" "error_message" "Unknown error")"
        echo "Agent ${role} errored: ${error_msg}"
        return 1
    fi

    echo "Agent ${role} completed (cost: \$${cost})"
    return 0
}

# ---------------------------------------------------------------------------
# Work directory setup — isolated git repo for generated code
# ---------------------------------------------------------------------------
ensure_work_dir() {
    mkdir -p "$WORK_DIR"

    if [[ ! -d "${WORK_DIR}/.git" ]]; then
        echo "Initializing git repo in ${WORK_DIR}..."
        git -C "$WORK_DIR" init -b main
        git -C "$WORK_DIR" commit --allow-empty -m "chore: initialize mjolnir project — ${PROJECT_NAME}"
        log_event "git_init" "work_dir=${WORK_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Sprint directory setup
# ---------------------------------------------------------------------------
ensure_sprint_dir() {
    local sprint_num="$1"
    local sprint_dir
    sprint_dir="$(printf "%s/sprints/%02d" "${PROJECT_DIR}" "$sprint_num")"
    mkdir -p "$sprint_dir"
    echo "$sprint_dir"
}

# ---------------------------------------------------------------------------
# Evaluation threshold check
# ---------------------------------------------------------------------------
check_thresholds() {
    local eval_file="$1"
    python3 - "$eval_file" "$THRESH_DESIGN" "$THRESH_ORIGINALITY" "$THRESH_CRAFT" "$THRESH_FUNCTIONALITY" <<'PYEOF'
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
        print(f"FAIL: {criterion} = {score} (threshold: {threshold})", file=sys.stderr)

sys.exit(0 if passed else 1)
PYEOF
}

# ---------------------------------------------------------------------------
# Count sprints in plan.md
# ---------------------------------------------------------------------------
count_sprints() {
    if [[ ! -f "${WORK_DIR}/plan.md" ]]; then
        echo "5"
        return
    fi
    local count
    count="$(grep -cE '^##+ Sprint [0-9]+' "${WORK_DIR}/plan.md" 2>/dev/null)" || true
    if [[ "$count" -gt 0 ]] 2>/dev/null; then
        echo "$count"
    else
        # Fallback: count lines matching sprint-like patterns (tables, lists)
        count="$(grep -ciE 'sprint [0-9]+' "${WORK_DIR}/plan.md" 2>/dev/null)" || true
        if [[ "$count" -gt 0 ]] 2>/dev/null; then
            echo "$count"
        else
            echo "5"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Build user prompts
# ---------------------------------------------------------------------------
build_planner_prompt() {
    cat <<PROMPT
Here is the project definition:

\`\`\`toml
$(cat "${PROJECT_DIR}/project.toml")
\`\`\`

Create a comprehensive build plan. Write the plan to \`plan.md\` in the current directory.
PROMPT
}

build_generator_prompt() {
    local sprint="$1"
    local sprint_dir="$2"
    local prev_feedback=""

    if [[ -f "${sprint_dir}/eval_report.json" ]]; then
        prev_feedback="

## Previous Evaluator Feedback (YOU MUST ADDRESS EVERY POINT)

\`\`\`json
$(cat "${sprint_dir}/eval_report.json")
\`\`\`"
    fi

    local plan_content=""
    if [[ -f "${WORK_DIR}/plan.md" ]]; then
        plan_content="$(cat "${WORK_DIR}/plan.md")"
    else
        echo "Warning: plan.md not found" >&2
        plan_content="(plan.md not found — implement based on project.toml goals)"
    fi

    cat <<PROMPT
## Build Plan

\`\`\`markdown
${plan_content}
\`\`\`

## Current Sprint: ${sprint}

Implement Sprint ${sprint} from the plan above. Read the sprint contract carefully and deliver all acceptance criteria.${prev_feedback}

## Scoring Rubric (you will be evaluated on this)

\`\`\`markdown
$(cat "${PROMPTS_DIR}/rubric.md")
\`\`\`

Start implementing now. Write complete, runnable code. Commit your work with descriptive messages.
If this project has a web UI, ensure the dev server is running when you finish so the evaluator can interact with it.
PROMPT
}

build_evaluator_prompt() {
    local sprint="$1"
    local sprint_dir="$2"
    local attempt="$3"

    local plan_content=""
    if [[ -f "${WORK_DIR}/plan.md" ]]; then
        plan_content="$(cat "${WORK_DIR}/plan.md")"
    else
        plan_content="(plan.md not found)"
    fi

    cat <<PROMPT
## Evaluation Task

Evaluate Sprint ${sprint} (attempt ${attempt}) of the project.

## Sprint Contract (from plan.md)

\`\`\`markdown
${plan_content}
\`\`\`

## Instructions

1. Read all code files in the project directory
2. If a web UI exists, use \`npx playwright screenshot http://localhost:5173 screenshot.png\` and other Playwright CLI commands to interact with it
3. Score against the rubric below
4. Write your evaluation to: ${sprint_dir}/eval_report.json

## Scoring Rubric

\`\`\`markdown
$(cat "${PROMPTS_DIR}/rubric.md")
\`\`\`

Be STRICT and HONEST. Write ONLY valid JSON to the eval_report.json file.
Set "sprint" to ${sprint} and "attempt" to ${attempt} in your report.
PROMPT
}

# ---------------------------------------------------------------------------
# Main orchestration loop
# ---------------------------------------------------------------------------
main() {
    echo "================================================"
    echo "  Mjolnir — Autonomous Coding Harness"
    echo "  Project: ${PROJECT_NAME}"
    echo "  Config:  ${PROJECT_DIR}"
    echo "  Output:  ${WORK_DIR}"
    echo "================================================"

    # Ensure work directory exists with its own git repo
    ensure_work_dir

    # Initialize state if needed
    if [[ ! -f "$STATE_FILE" ]]; then
        state_cmd init > /dev/null
    fi

    local phase
    phase="$(get_phase)"

    # Check if already complete
    if [[ "$phase" == "complete" ]]; then
        echo "Project already complete. Delete state.json to re-run."
        exit 0
    fi

    # Check if halted (manual intervention needed)
    if [[ "$phase" == "halted" ]]; then
        echo "Project is halted. Edit state.json to resume, then re-run."
        exit 1
    fi

    # Handle rate limit resume
    if [[ "$phase" == "rate_limited" ]]; then
        check_and_wait_rate_limit
        phase="$(get_phase)"
    fi

    # Handle resume during evaluation — skip back to generating for retry
    if [[ "$phase" == "evaluating" ]]; then
        echo "Resuming from interrupted evaluation — will re-run this sprint"
        phase="generating"
    fi

    notify "Mjolnir started: ${PROJECT_NAME}" "info"
    log_event "mjolnir_start" "project=${PROJECT_NAME}"

    # -----------------------------------------------------------------------
    # PHASE 1: PLANNING
    # -----------------------------------------------------------------------
    if [[ "$phase" == "idle" || "$phase" == "planning" ]]; then
        echo ""
        echo "=== Phase: PLANNING (mode: ${PLANNING_MODE}) ==="
        state_cmd transition planning > /dev/null
        log_event "phase_start" "phase=planning" "mode=${PLANNING_MODE}"
        notify "Planning phase started (${PLANNING_MODE})" "info"

        local planner_ok=false

        if [[ "$PLANNING_MODE" == "interactive" ]]; then
            # Interactive mode: send project context first, then open live session
            echo ""
            echo "Opening interactive planning session..."
            echo "Collaborate with Claude to create plan.md in ${WORK_DIR}"
            echo "When done, exit the session (/exit or Ctrl+D)."
            echo ""

            # Step 1: Send the project context as a seed message via -p
            #         This creates a session the user can resume interactively.
            local seed_session_id
            seed_session_id="$(claude -p \
                --dangerously-skip-permissions \
                --output-format json \
                --system-prompt "$(cat "${PROMPTS_DIR}/planner.md")" \
                -d "$WORK_DIR" \
                "$(build_planner_prompt)" 2>/dev/null \
                | python3 -c "import json,sys; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)" || true

            # Step 2: Resume that session interactively so the user can collaborate
            if [[ -n "$seed_session_id" ]]; then
                claude \
                    --dangerously-skip-permissions \
                    --resume "$seed_session_id" \
                    -d "$WORK_DIR" || true
            else
                # Fallback: just open a fresh interactive session with the prompt
                claude \
                    --dangerously-skip-permissions \
                    --system-prompt "$(cat "${PROMPTS_DIR}/planner.md")" \
                    -d "$WORK_DIR" || true
            fi
            planner_ok=true

        else
            # Auto mode: headless planning via claude -p
            if run_agent "planner" "${PROMPTS_DIR}/planner.md" "$(build_planner_prompt)" "2" "${WORK_DIR}"; then
                planner_ok=true
                if [[ ! -f "${WORK_DIR}/plan.md" ]]; then
                    # Fallback: extract plan from agent text output
                    echo "Planner did not write plan.md — extracting from agent output..."
                    if [[ -f "${PROJECT_DIR}/.last_agent_output" ]]; then
                        cp "${PROJECT_DIR}/.last_agent_output" "${WORK_DIR}/plan.md"
                        echo "Wrote plan.md from planner text output ($(wc -c < "${WORK_DIR}/plan.md") bytes)"
                    fi
                fi
            fi
        fi

        if [[ "$planner_ok" != "true" ]]; then
            state_cmd transition error last_error='"Planner agent failed"' > /dev/null
            notify "Planner agent failed" "error"
            exit 1
        fi

        if [[ ! -f "${WORK_DIR}/plan.md" ]]; then
            echo "Error: plan.md not found in ${WORK_DIR}"
            echo "The planning session must produce a plan.md file."
            state_cmd transition error last_error='"Planner did not produce plan.md"' > /dev/null
            notify "Planner failed: no plan.md produced" "error"
            exit 1
        fi

        local total_sprints
        total_sprints="$(count_sprints)"

        # Respect max_sprints config
        if [[ "$MAX_SPRINTS" -gt 0 && "$total_sprints" -gt "$MAX_SPRINTS" ]]; then
            total_sprints="$MAX_SPRINTS"
        fi

        state_cmd transition generating sprint=1 attempt=0 total_sprints="$total_sprints" > /dev/null
        log_event "planning_done" "total_sprints=${total_sprints}"
        notify "Planning done. ${total_sprints} sprints planned." "success"
        echo "Plan complete: ${total_sprints} sprints"
    fi

    # -----------------------------------------------------------------------
    # PHASE 2+3: GENERATE / EVALUATE LOOP
    # -----------------------------------------------------------------------
    local sprint
    sprint="$(get_sprint)"
    local total_sprints
    total_sprints="$(get_total_sprints)"

    while [[ "$sprint" -le "$total_sprints" ]]; do
        local sprint_dir
        sprint_dir="$(ensure_sprint_dir "$sprint")"
        local attempt
        attempt="$(get_attempt)"
        local passed=false

        while [[ "$attempt" -lt "$MAX_RETRIES" ]]; do
            attempt=$((attempt + 1))
            state_cmd transition generating attempt="$attempt" > /dev/null

            echo ""
            echo "=== Sprint ${sprint}/${total_sprints} — Attempt ${attempt}/${MAX_RETRIES} ==="
            log_event "sprint_start" "sprint=${sprint}" "attempt=${attempt}"
            notify "Sprint ${sprint}/${total_sprints} attempt ${attempt}" "info"

            # --- GENERATE ---
            echo "--- Generating ---"
            if ! run_agent "generator" "${PROMPTS_DIR}/generator.md" \
                "$(build_generator_prompt "$sprint" "$sprint_dir")" \
                "$BUDGET_PER_SPRINT" "${WORK_DIR}"; then
                log_event "generator_error" "sprint=${sprint}" "attempt=${attempt}"
                notify "Generator failed on sprint ${sprint}" "warning"
                continue  # retry
            fi

            # --- EVALUATE ---
            echo "--- Evaluating ---"
            state_cmd transition evaluating > /dev/null

            if ! run_agent "evaluator" "${PROMPTS_DIR}/evaluator.md" \
                "$(build_evaluator_prompt "$sprint" "$sprint_dir" "$attempt")" \
                "10" "${WORK_DIR}"; then
                log_event "evaluator_error" "sprint=${sprint}" "attempt=${attempt}"
                notify "Evaluator failed on sprint ${sprint}" "warning"
                continue  # retry
            fi

            # --- THRESHOLD CHECK ---
            if [[ ! -f "${sprint_dir}/eval_report.json" ]]; then
                echo "Warning: Evaluator did not produce eval_report.json"
                log_event "eval_missing" "sprint=${sprint}"
                continue
            fi

            if check_thresholds "${sprint_dir}/eval_report.json"; then
                passed=true
                local scores
                scores="$(python3 - "${sprint_dir}/eval_report.json" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
print(json.dumps(r["scores"]))
PYEOF
)"
                log_event "sprint_pass" "sprint=${sprint}" "scores=${scores}"
                notify "Sprint ${sprint} PASSED: ${scores}" "success"
                echo "Sprint ${sprint} PASSED!"
                break
            else
                local scores
                scores="$(python3 - "${sprint_dir}/eval_report.json" <<'PYEOF' 2>/dev/null || echo '{}'
import json, sys
with open(sys.argv[1]) as f:
    r = json.load(f)
print(json.dumps(r["scores"]))
PYEOF
)"
                log_event "sprint_fail" "sprint=${sprint}" "attempt=${attempt}" "scores=${scores}"
                notify "Sprint ${sprint} attempt ${attempt} FAILED" "warning"
                echo "Sprint ${sprint} attempt ${attempt} FAILED — retrying with feedback"
            fi
        done

        if [[ "$passed" != "true" ]]; then
            echo ""
            echo "Sprint ${sprint} FAILED after ${MAX_RETRIES} attempts. Halting."
            state_cmd transition halted last_error="\"Sprint ${sprint} failed after ${MAX_RETRIES} attempts\"" > /dev/null
            notify "Sprint ${sprint} FAILED after ${MAX_RETRIES} attempts. Halting." "error"
            exit 1
        fi

        # Advance to next sprint
        sprint=$((sprint + 1))
        if [[ "$sprint" -le "$total_sprints" ]]; then
            state_cmd transition generating sprint="$sprint" attempt=0 > /dev/null
        fi
    done

    # -----------------------------------------------------------------------
    # COMPLETE
    # -----------------------------------------------------------------------
    state_cmd transition complete > /dev/null
    local total_cost
    total_cost="$(python3 - "${STATE_FILE}" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    s = json.load(f)
print(round(sum(s["costs"].values()), 2))
PYEOF
)"
    log_event "mjolnir_complete" "total_cost=${total_cost}"
    notify "Mjolnir complete! ${PROJECT_NAME} — Total cost: \$${total_cost}" "success"

    echo ""
    echo "================================================"
    echo "  Mjolnir COMPLETE"
    echo "  Project: ${PROJECT_NAME}"
    echo "  Total cost: \$${total_cost}"
    echo "================================================"
}

main "$@"
