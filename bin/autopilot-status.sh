#!/usr/bin/env bash
# autopilot-status.sh — Dashboard showing system status
# Usage: autopilot-status.sh [project_name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
setup_cron_env

FILTER_PROJECT="${1:-}"

# ── Header ──
echo "╔══════════════════════════════════════════════════╗"
echo "║           AUTOPILOT STATUS DASHBOARD             ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Cron Status ──
echo "── Cron ──"
if crontab -l 2>/dev/null | grep -q "autopilot-poll"; then
    CRON_ENTRY="$(crontab -l 2>/dev/null | grep "autopilot-poll")"
    echo "  Status: ACTIVE"
    echo "  Entry:  $CRON_ENTRY"
else
    echo "  Status: NOT INSTALLED"
    echo "  Install: */2 * * * * ~/autopilot/bin/autopilot-poll.sh >> ~/autopilot/var/logs/poll.log 2>&1"
fi
echo ""

# ── Last Poll ──
echo "── Last Poll ──"
POLL_LOG="$AUTOPILOT_LOGS/poll.log"
if [[ -f "$POLL_LOG" ]]; then
    LAST_POLL="$(tail -1 "$POLL_LOG" 2>/dev/null || echo "empty")"
    LOG_SIZE="$(du -h "$POLL_LOG" | cut -f1)"
    echo "  Last entry: $LAST_POLL"
    echo "  Log size:   $LOG_SIZE"
else
    echo "  No poll log yet"
fi
echo ""

# ── Projects ──
echo "── Registered Projects ──"
PROJECTS_CONF="$AUTOPILOT_ETC/projects.conf"
if [[ ! -f "$PROJECTS_CONF" ]] || [[ ! -s "$PROJECTS_CONF" ]]; then
    echo "  No projects registered"
    echo "  Register: autopilot-register.sh <git_url>"
    echo ""
else
    while IFS=' ' read -r project_name git_url; do
        [[ -z "$project_name" ]] && continue
        [[ -n "$FILTER_PROJECT" && "$project_name" != "$FILTER_PROJECT" ]] && continue

        project_dir="$(get_project_dir "$project_name")"
        state_dir="$(get_state_dir "$project_name")"

        echo ""
        echo "  ┌─ $project_name"
        echo "  │  URL: $git_url"
        echo "  │  Dir: $project_dir"

        # Git status
        if [[ -d "$project_dir/.git" ]]; then
            cd "$project_dir"
            BRANCH="$(get_current_branch 2>/dev/null || echo "unknown")"
            HEAD="$(get_head_commit 2>/dev/null || echo "unknown")"
            echo "  │  Branch: $BRANCH  HEAD: ${HEAD:0:8}"
        else
            echo "  │  Git: NOT CLONED"
        fi

        # State
        LAST_COMMIT="$(get_last_commit "$project_name")"
        FIX_COUNT="$(get_fix_cycle_count "$project_name")"
        echo "  │  Last known commit: ${LAST_COMMIT:0:8}"
        echo "  │  Fix cycle: $FIX_COUNT / ${AUTOPILOT_MAX_FIX_CYCLES:-3}"

        # Lock status
        LOCKFILE="$state_dir/lock"
        if [[ -f "$LOCKFILE" ]] && flock -n "$LOCKFILE" true 2>/dev/null; then
            echo "  │  Lock: free"
        else
            echo "  │  Lock: HELD (process running)"
        fi

        # Active SLURM jobs
        ACTIVE_JOBS="$(squeue -u "$USER" --name="ap_${project_name}*" -h 2>/dev/null | wc -l || echo "0")"
        echo "  │  Active SLURM jobs: $ACTIVE_JOBS"

        # Recent runs
        RUNS_DIR="$AUTOPILOT_RUNS/$project_name"
        if [[ -d "$RUNS_DIR" ]]; then
            RECENT_RUNS="$(ls -1t "$RUNS_DIR" 2>/dev/null | head -3)"
            if [[ -n "$RECENT_RUNS" ]]; then
                echo "  │  Recent runs:"
                while IFS= read -r run; do
                    RUN_PATH="$RUNS_DIR/$run"
                    if [[ -f "$RUN_PATH/claude_review.md" ]]; then
                        REVIEW_STATUS="reviewed"
                    else
                        REVIEW_STATUS="pending"
                    fi
                    echo "  │    $run ($REVIEW_STATUS)"
                done <<< "$RECENT_RUNS"
            fi
        fi
        echo "  └──"

    done < <(grep -v '^\s*#' "$PROJECTS_CONF" | grep -v '^\s*$')
fi

echo ""
echo "── System ──"
echo "  User: $USER"
echo "  Autopilot home: $AUTOPILOT_HOME"
echo "  Git: $(git --version 2>/dev/null || echo "not loaded (module load git)")"
echo "  Claude: $(which claude 2>/dev/null || echo "not found")"
echo "  Python: $(python3 --version 2>/dev/null || echo "not found")"
echo ""
