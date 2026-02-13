#!/usr/bin/env bash
# autopilot-run.sh — Pull latest code, parse cluster.yaml, submit SLURM jobs.
# Usage: autopilot-run.sh <project_name> <branch>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

PROJECT_NAME="${1:?Usage: autopilot-run.sh <project_name> <branch>}"
BRANCH="${2:-main}"

project_dir="$(get_project_dir "$PROJECT_NAME")"
cd "$project_dir"

log_info "[$PROJECT_NAME] Starting run on branch $BRANCH"

# ── Git Pull (fast-forward only) ──
log_info "[$PROJECT_NAME] Pulling latest changes (--ff-only)"
if ! git pull --ff-only origin "$BRANCH" 2>&1; then
    log_error "[$PROJECT_NAME] git pull --ff-only failed. Possible divergence."
    send_notification "$PROJECT_NAME: git pull failed" \
        "Fast-forward pull failed for $PROJECT_NAME on branch $BRANCH. Manual merge may be required."
    exit 1
fi

# ── Parse cluster.yaml ──
CLUSTER_YAML="$project_dir/cluster.yaml"
if [[ ! -f "$CLUSTER_YAML" ]]; then
    log_error "[$PROJECT_NAME] No cluster.yaml found in project root"
    exit 1
fi

log_info "[$PROJECT_NAME] Parsing cluster.yaml"
PARSED_CONFIG="$(python3 "$AUTOPILOT_LIB/parse_cluster_yaml.py" "$CLUSTER_YAML")"
eval "$PARSED_CONFIG"

log_info "[$PROJECT_NAME] Found $NUM_JOBS job(s) to submit"

# ── Create Run Directory ──
RUN_DIR="$(create_run_dir "$PROJECT_NAME")"
log_info "[$PROJECT_NAME] Run directory: $RUN_DIR"

# Save metadata
cat > "$RUN_DIR/run.json" <<EOJSON
{
    "project": "$PROJECT_NAME",
    "branch": "$BRANCH",
    "commit": "$(git rev-parse HEAD)",
    "commit_msg": "$(git log --format='%s' -1 | sed 's/"/\\"/g')",
    "timestamp": "$(date -Iseconds)",
    "cluster_yaml": "$CLUSTER_YAML",
    "run_dir": "$RUN_DIR"
}
EOJSON

# ── Submit SLURM Jobs ──
# Build a name->job_id map for dependency resolution
declare -A JOB_ID_MAP=()
ALL_JOB_IDS=()

for ((i = 0; i < NUM_JOBS; i++)); do
    # Read job config variables
    name_var="JOB_${i}_NAME"; job_name="${!name_var}"
    script_var="JOB_${i}_SCRIPT"; job_script="${!script_var}"
    type_var="JOB_${i}_TYPE"; job_type="${!type_var}"
    array_var="JOB_${i}_ARRAY"; job_array="${!array_var}"
    depends_var="JOB_${i}_DEPENDS_ON"; job_depends="${!depends_var}"
    flags_var="JOB_${i}_SBATCH_FLAGS"; sbatch_flags="${!flags_var}"

    log_info "[$PROJECT_NAME] Submitting job $((i+1))/$NUM_JOBS: $job_name ($job_script)"

    # Build sbatch command
    SBATCH_CMD="sbatch"
    SBATCH_CMD+=" --job-name=ap_${PROJECT_NAME}_${job_name}"
    SBATCH_CMD+=" --output=$RUN_DIR/${job_name}_%j_%a.out"
    SBATCH_CMD+=" --error=$RUN_DIR/${job_name}_%j_%a.err"

    # Array jobs
    if [[ -n "$job_array" ]]; then
        SBATCH_CMD+=" --array=$job_array"
    fi

    # Resolve dependencies
    if [[ -n "$job_depends" ]]; then
        dep_ids=""
        IFS=',' read -ra DEP_NAMES <<< "$job_depends"
        for dep_name in "${DEP_NAMES[@]}"; do
            dep_name="$(echo "$dep_name" | tr -d ' ')"
            if [[ -n "${JOB_ID_MAP[$dep_name]:-}" ]]; then
                if [[ -n "$dep_ids" ]]; then
                    dep_ids+=":${JOB_ID_MAP[$dep_name]}"
                else
                    dep_ids="${JOB_ID_MAP[$dep_name]}"
                fi
            else
                log_error "[$PROJECT_NAME] Job $job_name depends on unknown job: $dep_name"
                exit 1
            fi
        done
        if [[ -n "$dep_ids" ]]; then
            SBATCH_CMD+=" --dependency=afterok:$dep_ids"
        fi
    fi

    # Export project dir and Slack vars so job scripts can find project files and post progress/images
    EXPORT_VARS="ALL,GATE_SIM_DIR=${project_dir}"
    if [[ -n "${AUTOPILOT_SLACK_WEBHOOK:-}" ]]; then
        EXPORT_VARS+=",AUTOPILOT_SLACK_WEBHOOK=${AUTOPILOT_SLACK_WEBHOOK}"
    fi
    if [[ -n "${AUTOPILOT_SLACK_TOKEN:-}" ]]; then
        EXPORT_VARS+=",AUTOPILOT_SLACK_TOKEN=${AUTOPILOT_SLACK_TOKEN}"
    fi
    if [[ -n "${AUTOPILOT_SLACK_CHANNEL:-}" ]]; then
        EXPORT_VARS+=",AUTOPILOT_SLACK_CHANNEL=${AUTOPILOT_SLACK_CHANNEL}"
    fi
    SBATCH_CMD+=" --export=${EXPORT_VARS}"

    # Extra sbatch flags from cluster.yaml
    if [[ -n "$sbatch_flags" ]]; then
        SBATCH_CMD+=" $sbatch_flags"
    fi

    SBATCH_CMD+=" $project_dir/$job_script"

    log_debug "[$PROJECT_NAME] Command: $SBATCH_CMD"

    # Submit and capture job ID
    SUBMIT_OUTPUT="$(eval "$SBATCH_CMD" 2>&1)"
    if [[ $? -ne 0 ]]; then
        log_error "[$PROJECT_NAME] Failed to submit job $job_name: $SUBMIT_OUTPUT"
        exit 1
    fi

    # Extract job ID from "Submitted batch job 12345"
    JOB_ID="$(echo "$SUBMIT_OUTPUT" | grep -oP 'Submitted batch job \K\d+')"
    if [[ -z "$JOB_ID" ]]; then
        log_error "[$PROJECT_NAME] Could not parse job ID from: $SUBMIT_OUTPUT"
        exit 1
    fi

    log_info "[$PROJECT_NAME] Job $job_name submitted: $JOB_ID"
    JOB_ID_MAP["$job_name"]="$JOB_ID"
    ALL_JOB_IDS+=("$JOB_ID")

    # Record in run metadata
    echo "$job_name=$JOB_ID" >> "$RUN_DIR/job_ids.txt"
done

# ── Submit Sentinel Job ──
# This lightweight job runs after ALL other jobs complete, triggering the review.
ALL_IDS_STR="$(IFS=':'; echo "${ALL_JOB_IDS[*]}")"

log_info "[$PROJECT_NAME] Submitting sentinel job (depends on: $ALL_IDS_STR)"

SENTINEL_SCRIPT="$RUN_DIR/sentinel.sh"
cat > "$SENTINEL_SCRIPT" <<'EOSENTINEL'
#!/usr/bin/env bash
# Sentinel job — triggers Claude review after all pipeline jobs complete
echo "Sentinel job started at $(date)"
echo "Run directory: $AUTOPILOT_RUN_DIR"
echo "Project: $AUTOPILOT_PROJECT"

# Run the review script
"$AUTOPILOT_BIN/autopilot-review.sh" "$AUTOPILOT_PROJECT" "$AUTOPILOT_RUN_DIR"

echo "Sentinel job finished at $(date)"
EOSENTINEL
chmod +x "$SENTINEL_SCRIPT"

SENTINEL_OUTPUT="$(sbatch \
    --job-name="ap_${PROJECT_NAME}_sentinel" \
    --output="$RUN_DIR/sentinel_%j.out" \
    --error="$RUN_DIR/sentinel_%j.err" \
    --dependency="afterany:$ALL_IDS_STR" \
    --partition="${AUTOPILOT_SENTINEL_PARTITION:-128x24}" \
    --cpus-per-task=1 \
    --mem=2G \
    --time="${AUTOPILOT_SENTINEL_TIME:-00:30:00}" \
    --export="AUTOPILOT_RUN_DIR=$RUN_DIR,AUTOPILOT_PROJECT=$PROJECT_NAME,AUTOPILOT_BIN=$AUTOPILOT_BIN,AUTOPILOT_HOME=$AUTOPILOT_HOME,HOME=$HOME,PATH=$PATH" \
    "$SENTINEL_SCRIPT" 2>&1)"

SENTINEL_ID="$(echo "$SENTINEL_OUTPUT" | grep -oP 'Submitted batch job \K\d+')"
if [[ -n "$SENTINEL_ID" ]]; then
    log_info "[$PROJECT_NAME] Sentinel job submitted: $SENTINEL_ID"
    echo "sentinel=$SENTINEL_ID" >> "$RUN_DIR/job_ids.txt"
else
    log_error "[$PROJECT_NAME] Failed to submit sentinel job: $SENTINEL_OUTPUT"
    exit 1
fi

# Save full run summary
cat >> "$RUN_DIR/run.json" <<EOSUMMARY

{
    "jobs_submitted": "$(cat "$RUN_DIR/job_ids.txt" | tr '\n' ', ')",
    "sentinel_job_id": "$SENTINEL_ID"
}
EOSUMMARY

# Build a summary of all submitted jobs for Slack
JOBS_SUMMARY=""
while IFS='=' read -r jn ji; do
    JOBS_SUMMARY+="• $jn → $ji\n"
done < "$RUN_DIR/job_ids.txt"

send_notification "$PROJECT_NAME: Pipeline submitted" \
    "Commit: $(git rev-parse --short HEAD) — $(git log --format='%s' -1)\nRun: $(basename "$RUN_DIR")\n\nJobs:\n${JOBS_SUMMARY}\nSentinel will trigger Claude review when all jobs complete."

log_info "[$PROJECT_NAME] All jobs submitted successfully. Sentinel will trigger review."
