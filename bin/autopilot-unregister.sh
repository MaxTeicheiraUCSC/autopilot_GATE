#!/usr/bin/env bash
# autopilot-unregister.sh — Remove a project from autopilot tracking
# Usage: autopilot-unregister.sh <project_name> [--clean]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

PROJECT_NAME="${1:?Usage: autopilot-unregister.sh <project_name> [--clean]}"
CLEAN="${2:-}"

PROJECTS_CONF="$AUTOPILOT_ETC/projects.conf"

# Check if registered
if [[ ! -f "$PROJECTS_CONF" ]] || ! grep -q "^$PROJECT_NAME " "$PROJECTS_CONF" 2>/dev/null; then
    log_error "Project '$PROJECT_NAME' is not registered"
    exit 1
fi

# Remove from projects.conf
TMPFILE="$(mktemp)"
grep -v "^$PROJECT_NAME " "$PROJECTS_CONF" > "$TMPFILE"
mv "$TMPFILE" "$PROJECTS_CONF"

log_info "Removed $PROJECT_NAME from projects.conf"

# Optionally clean state
if [[ "$CLEAN" == "--clean" ]]; then
    log_info "Cleaning state for $PROJECT_NAME..."

    if [[ -d "$AUTOPILOT_STATE/$PROJECT_NAME" ]]; then
        rm -rf "$AUTOPILOT_STATE/$PROJECT_NAME"
        log_info "  Removed state: $AUTOPILOT_STATE/$PROJECT_NAME"
    fi

    if [[ -d "$AUTOPILOT_RUNS/$PROJECT_NAME" ]]; then
        rm -rf "$AUTOPILOT_RUNS/$PROJECT_NAME"
        log_info "  Removed runs: $AUTOPILOT_RUNS/$PROJECT_NAME"
    fi

    echo "Project '$PROJECT_NAME' unregistered and cleaned."
else
    echo "Project '$PROJECT_NAME' unregistered."
    echo "State and run history preserved. Use --clean to remove them."
fi
