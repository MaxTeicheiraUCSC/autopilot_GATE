#!/usr/bin/env bash
# autopilot-poll.sh — Cron entry point. Polls all registered projects for new commits.
# Usage: */2 * * * * ~/autopilot/bin/autopilot-poll.sh >> ~/autopilot/var/logs/poll.log 2>&1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# Bootstrap cron environment (modules, conda, etc.)
setup_cron_env

log_info "=== Poll cycle starting ==="

PROJECTS_CONF="$AUTOPILOT_ETC/projects.conf"
if [[ ! -f "$PROJECTS_CONF" ]]; then
    log_info "No projects.conf found, nothing to poll"
    exit 0
fi

# ── Monitor active jobs for all projects (sends Slack on state changes) ──
while IFS=' ' read -r _proj _url; do
    [[ -z "$_proj" ]] && continue
    monitor_jobs "$_proj"
done < <(get_projects)

# Process each project
while IFS=' ' read -r project_name git_url; do
    [[ -z "$project_name" ]] && continue

    log_info "Polling project: $project_name"

    project_dir="$(get_project_dir "$project_name")"

    if [[ ! -d "$project_dir/.git" ]]; then
        log_warn "Project directory $project_dir is not a git repo, skipping"
        continue
    fi

    # Acquire per-project lock (prevents concurrent poll/run on same project)
    if ! acquire_lock "$project_name"; then
        log_warn "Skipping $project_name — another process holds the lock"
        continue
    fi

    (
        cd "$project_dir"

        branch="$(get_current_branch)"
        if [[ -z "$branch" ]]; then
            log_error "Could not determine current branch for $project_name"
            release_lock
            exit 0
        fi

        # Fetch latest from remote
        if ! git fetch origin "$branch" 2>&1; then
            log_error "git fetch failed for $project_name"
            release_lock
            exit 0
        fi

        remote_head="$(get_remote_head "$branch")"

        if [[ -z "$remote_head" ]]; then
            log_warn "Could not determine remote HEAD for $project_name (origin/$branch)"
            release_lock
            exit 0
        fi

        # Compare remote HEAD against stored last_commit (not local HEAD)
        # This correctly detects new commits even when pushing from the same clone.
        last_known="$(get_last_commit "$project_name")"

        if [[ "$last_known" == "$remote_head" ]]; then
            log_info "$project_name: No new commits (remote=$remote_head)"
            release_lock
            exit 0
        fi

        log_info "$project_name: New commits detected! $last_known -> $remote_head"
        latest_msg="$(git log --format='%s' "origin/$branch" -1)"
        send_notification "$project_name: New commit detected" \
            "Commit: ${remote_head:0:8}\nMessage: $latest_msg\nBranch: $branch\nTriggering pipeline..."

        # Check if the latest remote commit is a human commit (not autopilot-fix)
        latest_msg="$(git log --format='%s' "origin/$branch" -1)"
        if is_human_commit "$latest_msg"; then
            log_info "$project_name: Human commit detected, resetting fix cycle counter"
            reset_fix_cycle "$project_name"
        fi

        # Check fix cycle limit before triggering
        fix_count="$(get_fix_cycle_count "$project_name")"
        max_cycles="${AUTOPILOT_MAX_FIX_CYCLES:-3}"
        if [[ "$fix_count" -ge "$max_cycles" ]]; then
            log_warn "$project_name: Fix cycle limit reached ($fix_count/$max_cycles). Waiting for human intervention."
            send_notification "$project_name: Fix cycle limit reached" \
                "Project $project_name has reached $fix_count fix cycles without success. Manual intervention required."
            release_lock
            exit 0
        fi

        # Trigger the run
        log_info "$project_name: Triggering autopilot-run.sh"
        "$AUTOPILOT_BIN/autopilot-run.sh" "$project_name" "$branch"

        # Update last known commit (after successful trigger)
        new_head="$(get_head_commit)"
        set_last_commit "$project_name" "$new_head"
    )

    release_lock
done < <(get_projects)

log_info "=== Poll cycle complete ==="
