#!/usr/bin/env bash
# autopilot-review.sh — Runs as SLURM sentinel. Collects logs, invokes Claude for analysis.
# Usage: autopilot-review.sh <project_name> <run_dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Bootstrap environment (we're in a SLURM job, may need modules/conda)
setup_cron_env

PROJECT_NAME="${1:?Usage: autopilot-review.sh <project_name> <run_dir>}"
RUN_DIR="${2:?Usage: autopilot-review.sh <project_name> <run_dir>}"

project_dir="$(get_project_dir "$PROJECT_NAME")"

log_info "[$PROJECT_NAME] Starting review for run: $RUN_DIR"

# ── Collect Job Results ──
SUMMARY_FILE="$RUN_DIR/job_summary.txt"
HAS_FAILURES=false

{
    echo "=== AUTOPILOT RUN SUMMARY ==="
    echo "Project: $PROJECT_NAME"
    echo "Run directory: $RUN_DIR"
    echo "Timestamp: $(date -Iseconds)"
    echo ""

    if [[ -f "$RUN_DIR/run.json" ]]; then
        echo "--- Run Metadata ---"
        cat "$RUN_DIR/run.json"
        echo ""
    fi

    echo "--- Job Results ---"

    if [[ -f "$RUN_DIR/job_ids.txt" ]]; then
        while IFS='=' read -r job_name job_id; do
            [[ "$job_name" == "sentinel" ]] && continue

            echo ""
            echo "Job: $job_name (ID: $job_id)"

            # Get job exit info from sacct
            JOB_INFO="$(sacct -j "$job_id" --format=JobID,State,ExitCode,Elapsed,MaxRSS --noheader -P 2>/dev/null || echo "unavailable")"
            echo "Status: $JOB_INFO"

            # Check for failures
            if echo "$JOB_INFO" | grep -qiE 'FAILED|TIMEOUT|OUT_OF_ME|CANCELLED|NODE_FAIL'; then
                HAS_FAILURES=true
                echo "*** FAILURE DETECTED ***"
            fi

            # Collect output logs (last 100 lines of each)
            echo ""
            echo "--- Output Logs ---"
            for logfile in "$RUN_DIR"/${job_name}_*.out; do
                if [[ -f "$logfile" ]]; then
                    echo ">> $(basename "$logfile") (last 100 lines):"
                    tail -100 "$logfile"
                    echo ""
                fi
            done

            echo "--- Error Logs ---"
            for logfile in "$RUN_DIR"/${job_name}_*.err; do
                if [[ -f "$logfile" ]]; then
                    ERR_CONTENT="$(cat "$logfile")"
                    if [[ -n "$ERR_CONTENT" ]]; then
                        echo ">> $(basename "$logfile"):"
                        tail -100 "$logfile"
                        echo ""
                        HAS_FAILURES=true
                    fi
                fi
            done

        done < "$RUN_DIR/job_ids.txt"
    fi
} > "$SUMMARY_FILE"

log_info "[$PROJECT_NAME] Job summary written to $SUMMARY_FILE"
log_info "[$PROJECT_NAME] Has failures: $HAS_FAILURES"

# ── Parse cluster.yaml for Claude config ──
CLUSTER_YAML="$project_dir/cluster.yaml"
if [[ -f "$CLUSTER_YAML" ]]; then
    eval "$(python3 "$AUTOPILOT_LIB/parse_cluster_yaml.py" "$CLUSTER_YAML")"
fi

CLAUDE_ENABLED="${CLAUDE_ENABLED:-false}"
CLAUDE_AUTO_FIX="${CLAUDE_AUTO_FIX:-false}"
CLAUDE_MAX_FIX_CYCLES="${CLAUDE_MAX_FIX_CYCLES:-3}"
CLAUDE_REVIEW_MODEL="${CLAUDE_REVIEW_MODEL:-sonnet}"
CLAUDE_FIX_MODEL="${CLAUDE_FIX_MODEL:-opus}"
CLAUDE_REVIEW_BUDGET="${CLAUDE_REVIEW_BUDGET:-0.50}"
CLAUDE_FIX_BUDGET="${CLAUDE_FIX_BUDGET:-1.00}"

if [[ "$CLAUDE_ENABLED" != "true" ]]; then
    log_info "[$PROJECT_NAME] Claude review disabled in cluster.yaml"
    send_notification "$PROJECT_NAME: Run complete (no review)" \
        "Jobs finished. Failures: $HAS_FAILURES. Claude review is disabled."
    exit 0
fi

# ── Claude Review (read-only analysis) ──
log_info "[$PROJECT_NAME] Running Claude review (model: $CLAUDE_REVIEW_MODEL, budget: \$$CLAUDE_REVIEW_BUDGET)"

REVIEW_PROMPT="You are reviewing the results of an automated SLURM simulation pipeline for the project '$PROJECT_NAME'.

Analyze the following job summary and provide:
1. Overall status (SUCCESS / PARTIAL FAILURE / COMPLETE FAILURE)
2. For each job: did it succeed? Any warnings?
3. If there are errors: identify the root cause, the specific file and line if possible
4. Recommended action: NONE (all good), FIX_NEEDED (describe what to fix), or INVESTIGATE (needs human review)

Be concise and actionable. Focus on errors and their root causes.

--- JOB SUMMARY ---
$(cat "$SUMMARY_FILE")
--- END SUMMARY ---"

REVIEW_OUTPUT="$RUN_DIR/claude_review.md"

if claude --print \
    --model "$CLAUDE_REVIEW_MODEL" \
    --max-budget-usd "$CLAUDE_REVIEW_BUDGET" \
    "$REVIEW_PROMPT" > "$REVIEW_OUTPUT" 2>"$RUN_DIR/claude_review_stderr.log"; then
    log_info "[$PROJECT_NAME] Claude review complete: $REVIEW_OUTPUT"
else
    log_error "[$PROJECT_NAME] Claude review failed (see $RUN_DIR/claude_review_stderr.log)"
    send_notification "$PROJECT_NAME: Claude review failed" \
        "Claude review process failed. Check $RUN_DIR/claude_review_stderr.log"
    exit 1
fi

# ── Auto-Fix (if enabled and failures detected) ──
if [[ "$HAS_FAILURES" == "true" && "$CLAUDE_AUTO_FIX" == "true" ]]; then
    fix_count="$(get_fix_cycle_count "$PROJECT_NAME")"

    if [[ "$fix_count" -ge "$CLAUDE_MAX_FIX_CYCLES" ]]; then
        log_warn "[$PROJECT_NAME] Fix cycle limit reached ($fix_count/$CLAUDE_MAX_FIX_CYCLES). Skipping auto-fix."
        send_notification "$PROJECT_NAME: Fix cycle limit reached" \
            "$(cat "$REVIEW_OUTPUT")"
        exit 0
    fi

    log_info "[$PROJECT_NAME] Attempting auto-fix (cycle $((fix_count+1))/$CLAUDE_MAX_FIX_CYCLES, model: $CLAUDE_FIX_MODEL)"

    cd "$project_dir"

    FIX_PROMPT="You are an automated CI/CD agent fixing a failed SLURM simulation pipeline.

Project: $PROJECT_NAME
Project directory: $project_dir
Fix cycle: $((fix_count+1)) of $CLAUDE_MAX_FIX_CYCLES

The previous run failed. Here is the review:
$(cat "$REVIEW_OUTPUT")

Here is the full job summary:
$(cat "$SUMMARY_FILE")

Your task:
1. Identify the root cause of the failure
2. Edit the necessary files to fix the issue
3. Test that your fix makes sense (don't run the full simulation, just check syntax/imports)
4. Commit your changes with a message starting with '[autopilot-fix]'
5. Push to origin

IMPORTANT:
- Only fix the identified issue, do not refactor or improve other code
- If you cannot determine the root cause with confidence, do NOT commit — just explain what you found
- All commits MUST be prefixed with '[autopilot-fix]'"

    FIX_LOG="$RUN_DIR/claude_fix.log"

    if claude \
        --model "$CLAUDE_FIX_MODEL" \
        --max-budget-usd "$CLAUDE_FIX_BUDGET" \
        --allowedTools "Bash,Read,Write,Edit,Glob,Grep" \
        "$FIX_PROMPT" > "$FIX_LOG" 2>"$RUN_DIR/claude_fix_stderr.log"; then
        log_info "[$PROJECT_NAME] Claude auto-fix complete. See $FIX_LOG"
        increment_fix_cycle "$PROJECT_NAME"

        # Check if Claude actually pushed a commit
        git fetch origin 2>/dev/null
        if [[ "$(get_head_commit)" != "$(get_remote_head "$(get_current_branch)")" ]]; then
            log_info "[$PROJECT_NAME] Fix commit detected. Next poll cycle will trigger a new run."
        else
            log_info "[$PROJECT_NAME] No fix commit was pushed (Claude may have deemed fix uncertain)."
        fi
    else
        log_error "[$PROJECT_NAME] Claude auto-fix failed (see $RUN_DIR/claude_fix_stderr.log)"
    fi

    send_notification "$PROJECT_NAME: Auto-fix attempted (cycle $((fix_count+1)))" \
        "Review: $(head -20 "$REVIEW_OUTPUT")\n\nFix log: $FIX_LOG"
else
    # No failures or auto-fix disabled
    if [[ "$HAS_FAILURES" == "true" ]]; then
        send_notification "$PROJECT_NAME: Run FAILED (auto-fix disabled)" \
            "$(cat "$REVIEW_OUTPUT")"
    else
        send_notification "$PROJECT_NAME: Run SUCCESS" \
            "$(head -10 "$REVIEW_OUTPUT")"
    fi
fi

log_info "[$PROJECT_NAME] Review complete."
