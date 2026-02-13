#!/usr/bin/env bash
# autopilot-register.sh — Clone a repo into ~/projects/ and add to projects.conf
# Usage: autopilot-register.sh <git_url> [project_name]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"
setup_cron_env

GIT_URL="${1:?Usage: autopilot-register.sh <git_url> [project_name]}"

# Derive project name from URL if not provided
if [[ -n "${2:-}" ]]; then
    PROJECT_NAME="$2"
else
    PROJECT_NAME="$(basename "$GIT_URL" .git)"
fi

PROJECTS_CONF="$AUTOPILOT_ETC/projects.conf"
PROJECT_DIR="$(get_project_dir "$PROJECT_NAME")"

# Check if already registered
if [[ -f "$PROJECTS_CONF" ]] && grep -q "^$PROJECT_NAME " "$PROJECTS_CONF" 2>/dev/null; then
    log_error "Project '$PROJECT_NAME' is already registered"
    exit 1
fi

# Clone or verify existing repo
if [[ -d "$PROJECT_DIR/.git" ]]; then
    log_info "Repository already exists at $PROJECT_DIR, verifying remote..."
    cd "$PROJECT_DIR"
    CURRENT_REMOTE="$(git remote get-url origin 2>/dev/null || echo "")"
    if [[ "$CURRENT_REMOTE" != "$GIT_URL" ]]; then
        log_error "Existing repo at $PROJECT_DIR has different remote: $CURRENT_REMOTE"
        log_error "Expected: $GIT_URL"
        exit 1
    fi
    log_info "Remote matches, using existing clone"
elif [[ -d "$PROJECT_DIR" ]]; then
    log_error "Directory $PROJECT_DIR exists but is not a git repository"
    exit 1
else
    log_info "Cloning $GIT_URL into $PROJECT_DIR"
    mkdir -p "$PROJECTS_DIR"
    git clone "$GIT_URL" "$PROJECT_DIR"
fi

# Initialize state directory
mkdir -p "$AUTOPILOT_STATE/$PROJECT_NAME"

# Record current HEAD as last known commit (don't trigger run on registration)
cd "$PROJECT_DIR"
CURRENT_HEAD="$(git rev-parse HEAD)"
set_last_commit "$PROJECT_NAME" "$CURRENT_HEAD"
reset_fix_cycle "$PROJECT_NAME"

# Add to projects.conf
mkdir -p "$(dirname "$PROJECTS_CONF")"
echo "$PROJECT_NAME $GIT_URL" >> "$PROJECTS_CONF"

log_info "Registered project: $PROJECT_NAME"
log_info "  URL: $GIT_URL"
log_info "  Directory: $PROJECT_DIR"
log_info "  Current HEAD: $CURRENT_HEAD"
echo ""
echo "Project '$PROJECT_NAME' registered successfully."
echo "Autopilot will check for new commits every poll cycle."
