#!/usr/bin/env bash
# common.sh — Shared functions for autopilot system

set -euo pipefail

# ── Paths ──
AUTOPILOT_HOME="${AUTOPILOT_HOME:-$HOME/autopilot}"
AUTOPILOT_BIN="$AUTOPILOT_HOME/bin"
AUTOPILOT_LIB="$AUTOPILOT_HOME/lib"
AUTOPILOT_ETC="$AUTOPILOT_HOME/etc"
AUTOPILOT_STATE="$AUTOPILOT_HOME/var/state"
AUTOPILOT_RUNS="$AUTOPILOT_HOME/var/runs"
AUTOPILOT_LOGS="$AUTOPILOT_HOME/var/logs"
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/projects}"

# ── Load global config ──
if [[ -f "$AUTOPILOT_ETC/global.conf" ]]; then
    source "$AUTOPILOT_ETC/global.conf"
fi

# ── Cron Environment Bootstrap ──
# In cron, modules/conda aren't available. Source them explicitly.
setup_cron_env() {
    # Temporarily disable nounset — lmod/conda init scripts reference unset vars
    set +u

    # Load lmod if module command is missing
    if ! type module &>/dev/null; then
        if [[ -f /usr/share/lmod/lmod/init/bash ]]; then
            source /usr/share/lmod/lmod/init/bash
        elif [[ -f /etc/profile.d/lmod.sh ]]; then
            source /etc/profile.d/lmod.sh
        elif [[ -f /usr/share/Modules/init/bash ]]; then
            source /usr/share/Modules/init/bash
        fi
    fi

    # Load git module
    module load git 2>/dev/null || true

    # Source conda
    if ! type conda &>/dev/null; then
        if [[ -f "$HOME/miniconda3/etc/profile.d/conda.sh" ]]; then
            source "$HOME/miniconda3/etc/profile.d/conda.sh"
        fi
    fi

    # Ensure ~/.local/bin is on PATH (for claude CLI, pip-installed tools)
    if [[ -d "$HOME/.local/bin" ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        export PATH="$HOME/.local/bin:$PATH"
    fi

    # Re-enable nounset
    set -u
}

# ── Logging ──
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() {
    if [[ "${AUTOPILOT_DEBUG:-0}" == "1" ]]; then
        log "DEBUG" "$@"
    fi
}

# ── Locking ──
# Usage: acquire_lock <project_name>
# Sets LOCK_FD global. Call release_lock when done.
LOCK_FD=""
acquire_lock() {
    local project="$1"
    local lockfile="$AUTOPILOT_STATE/$project/lock"
    mkdir -p "$(dirname "$lockfile")"

    exec {LOCK_FD}>"$lockfile"
    if ! flock -n "$LOCK_FD"; then
        log_warn "Could not acquire lock for $project (another process is running)"
        return 1
    fi
    log_debug "Acquired lock for $project"
    return 0
}

release_lock() {
    if [[ -n "$LOCK_FD" ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        exec {LOCK_FD}>&- 2>/dev/null || true
        LOCK_FD=""
    fi
}

# ── State Management ──
get_state_dir() {
    local project="$1"
    local dir="$AUTOPILOT_STATE/$project"
    mkdir -p "$dir"
    echo "$dir"
}

get_last_commit() {
    local project="$1"
    local state_dir
    state_dir="$(get_state_dir "$project")"
    if [[ -f "$state_dir/last_commit" ]]; then
        cat "$state_dir/last_commit"
    else
        echo ""
    fi
}

set_last_commit() {
    local project="$1" commit="$2"
    local state_dir
    state_dir="$(get_state_dir "$project")"
    echo "$commit" > "$state_dir/last_commit"
}

get_fix_cycle_count() {
    local project="$1"
    local state_dir
    state_dir="$(get_state_dir "$project")"
    if [[ -f "$state_dir/fix_cycle_count" ]]; then
        cat "$state_dir/fix_cycle_count"
    else
        echo "0"
    fi
}

set_fix_cycle_count() {
    local project="$1" count="$2"
    local state_dir
    state_dir="$(get_state_dir "$project")"
    echo "$count" > "$state_dir/fix_cycle_count"
}

increment_fix_cycle() {
    local project="$1"
    local count
    count="$(get_fix_cycle_count "$project")"
    set_fix_cycle_count "$project" "$((count + 1))"
}

reset_fix_cycle() {
    local project="$1"
    set_fix_cycle_count "$project" "0"
}

# ── Run Directory ──
create_run_dir() {
    local project="$1"
    local run_id
    run_id="$(date '+%Y%m%d_%H%M%S')_$(head -c 4 /dev/urandom | xxd -p)"
    local run_dir="$AUTOPILOT_RUNS/$project/$run_id"
    mkdir -p "$run_dir"
    echo "$run_dir"
}

# ── SLURM Helpers ──
is_job_running() {
    local job_id="$1"
    squeue -j "$job_id" -h 2>/dev/null | grep -q .
}

get_job_state() {
    local job_id="$1"
    sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | head -1 | tr -d ' '
}

# ── Projects Config ──
get_projects() {
    local projects_conf="$AUTOPILOT_ETC/projects.conf"
    if [[ ! -f "$projects_conf" ]]; then
        return
    fi
    # Each line: project_name git_url
    grep -v '^\s*#' "$projects_conf" | grep -v '^\s*$' || true
}

get_project_dir() {
    local project="$1"
    echo "$PROJECTS_DIR/$project"
}

# ── Notifications ──
send_slack() {
    local subject="$1" body="$2"
    local webhook="${AUTOPILOT_SLACK_WEBHOOK:-}"

    if [[ -z "$webhook" ]]; then
        return
    fi

    # Convert literal \n sequences to real newlines
    body="$(printf '%b' "$body")"

    # Truncate body to 3000 chars (Slack block limit)
    local truncated_body="${body:0:3000}"
    if [[ ${#body} -gt 3000 ]]; then
        truncated_body+="... (truncated)"
    fi

    # Build JSON payload via Python for proper escaping
    local payload
    payload="$(python3 -c "
import json, sys
subject = sys.argv[1]
body = sys.argv[2]
ts = sys.argv[3]
host = sys.argv[4]
print(json.dumps({
    'blocks': [
        {'type': 'header', 'text': {'type': 'plain_text', 'text': subject, 'emoji': True}},
        {'type': 'section', 'text': {'type': 'mrkdwn', 'text': body}},
        {'type': 'context', 'elements': [{'type': 'mrkdwn', 'text': f'autopilot | {ts} | {host}'}]},
    ]
}))
" "$subject" "$truncated_body" "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)")"

    curl -s -X POST -H 'Content-type: application/json' \
        --data "$payload" \
        "$webhook" >/dev/null 2>&1 || \
        log_warn "Failed to send Slack notification"
}

send_notification() {
    local subject="$1" body="$2"
    local email="${AUTOPILOT_EMAIL:-}"

    # Slack
    send_slack "$subject" "$body"

    # Email (if configured)
    if [[ -n "$email" ]]; then
        echo "$body" | mail -s "[autopilot] $subject" "$email" 2>/dev/null || \
            log_warn "Failed to send email notification"
    fi

    # Always log
    log_info "NOTIFICATION: $subject"
}

# ── Job Status Tracking ──
# Checks all active runs for a project, logs and notifies on state transitions.
# State file: var/state/<project>/job_states  (format: KEY STATE)
monitor_jobs() {
    local project="$1"
    local state_dir
    state_dir="$(get_state_dir "$project")"
    local states_file="$state_dir/job_states"
    local runs_dir="$AUTOPILOT_RUNS/$project"

    [[ -d "$runs_dir" ]] || return 0

    for run_dir in "$runs_dir"/*/; do
        [[ -f "${run_dir}job_ids.txt" ]] || continue

        local run_name
        run_name="$(basename "$run_dir")"

        while IFS='=' read -r job_name job_id; do
            [[ -z "$job_id" ]] && continue

            # Get current state from SLURM (first non-empty line)
            local current_state
            current_state="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | head -1 | tr -d ' ' || true)"
            [[ -z "$current_state" ]] && current_state="UNKNOWN"

            # For array jobs, build a progress summary
            local array_info=""
            local total_tasks running_tasks pending_tasks completed_tasks failed_tasks
            total_tasks="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | wc -l || true)"
            if [[ "$total_tasks" -gt 1 ]]; then
                running_tasks="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | grep -c 'RUNNING' || true)"
                pending_tasks="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | grep -c 'PENDING' || true)"
                completed_tasks="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | grep -c 'COMPLETED' || true)"
                failed_tasks="$(sacct -j "$job_id" --format=State --noheader -P 2>/dev/null | grep -c 'FAILED' || true)"
                array_info=" [R:${running_tasks} PD:${pending_tasks} OK:${completed_tasks} FAIL:${failed_tasks}/${total_tasks}]"
            fi

            # Compose a state string that includes array info so transitions fire on progress changes too
            local full_state="${current_state}${array_info}"

            # Look up previous state
            local prev_state=""
            local state_key="${run_name}_${job_id}"
            if [[ -f "$states_file" ]]; then
                prev_state="$(grep "^${state_key} " "$states_file" 2>/dev/null | sed "s/^${state_key} //" || true)"
            fi

            # Log and notify on any change
            if [[ "$full_state" != "$prev_state" ]]; then
                log_info "[$project] Job $job_name ($job_id): ${prev_state:-NEW} -> $full_state"

                # Notify on important transitions (check base state)
                case "$current_state" in
                    RUNNING)
                        send_notification "$project — $job_name is running" \
                            ":gear: *$job_name* (SLURM $job_id) just started running on the cluster.$array_info\n\n_Run: ${run_name}_"
                        ;;
                    COMPLETED)
                        send_notification "$project — $job_name finished" \
                            ":white_check_mark: *$job_name* (SLURM $job_id) completed successfully!$array_info\n\n_Run: ${run_name}_"
                        ;;
                    FAILED|TIMEOUT|OUT_OF_ME*|NODE_FAIL)
                        send_notification "$project — $job_name FAILED" \
                            ":x: *$job_name* (SLURM $job_id) ended with *$current_state*$array_info\n\nCheck the logs in the run directory for details.\n_Run: ${run_name}_"
                        ;;
                    PENDING)
                        # Only notify on first time seeing PENDING (initial submission)
                        if [[ -z "$prev_state" ]]; then
                            send_notification "$project — $job_name queued" \
                                ":hourglass_flowing_sand: *$job_name* (SLURM $job_id) is waiting in the queue.$array_info\n\n_Run: ${run_name}_"
                        fi
                        ;;
                esac

                # Update stored state (replace line or append)
                if [[ -f "$states_file" ]]; then
                    local tmpfile="${states_file}.tmp"
                    grep -v "^${state_key} " "$states_file" > "$tmpfile" 2>/dev/null || true
                    mv "$tmpfile" "$states_file"
                fi
                echo "${state_key} ${full_state}" >> "$states_file"
            fi

        done < "${run_dir}job_ids.txt"
    done

    return 0
}

# ── Failure Classification ──
# Classify a SLURM failure state as transient or permanent.
# Returns: "transient" or "permanent"
classify_failure() {
    local state="$1"
    case "$state" in
        NODE_FAIL|TIMEOUT|OUT_OF_MEMORY)
            echo "transient"
            ;;
        FAILED|CANCELLED|PREEMPTED)
            echo "permanent"
            ;;
        *)
            echo "permanent"
            ;;
    esac
}

# Get the number of retry attempts for a job in a run.
get_retry_count() {
    local run_dir="$1" job_name="$2"
    local retry_state="$run_dir/retry_state.json"
    if [[ -f "$retry_state" ]]; then
        python3 -c "
import json, sys
with open('$retry_state') as f:
    data = json.load(f)
retries = data.get('retries', {}).get('$job_name', {})
attempts = retries.get('attempts', [])
print(len(attempts))
" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

# Check if any retry config exists in parsed cluster.yaml variables.
has_retry_config() {
    local num_jobs="${NUM_JOBS:-0}"
    for ((i = 0; i < num_jobs; i++)); do
        local retry_var="JOB_${i}_RETRY_MAX_RETRIES"
        local max_retries="${!retry_var:-0}"
        if [[ "$max_retries" -gt 0 ]]; then
            return 0  # true
        fi
    done
    return 1  # false
}

# ── Git Helpers ──
is_human_commit() {
    local commit_msg="$1"
    # Returns 0 (true) if this is NOT an autopilot-fix commit
    [[ ! "$commit_msg" =~ ^\[autopilot-fix\] ]]
}

get_head_commit() {
    git rev-parse HEAD 2>/dev/null
}

get_remote_head() {
    local branch="${1:-main}"
    git rev-parse "origin/$branch" 2>/dev/null
}

get_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}
