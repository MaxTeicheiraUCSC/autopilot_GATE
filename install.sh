#!/usr/bin/env bash
# install.sh — Install autopilot CI/CD system
# Idempotent: safe to re-run on an existing installation.
#
# Modes:
#   In-place:  Run from an existing autopilot directory (script dir == target dir)
#   Clone:     Run from a cloned repo to install into ~/autopilot

set -euo pipefail

# ── Detect mode ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${AUTOPILOT_HOME:-$HOME/autopilot}"

if [[ "$SCRIPT_DIR" == "$TARGET_DIR" ]]; then
    MODE="in-place"
else
    MODE="clone"
fi

echo "=== Autopilot Installer ==="
echo "Mode:   $MODE"
echo "Source: $SCRIPT_DIR"
echo "Target: $TARGET_DIR"
echo ""

# ── Check dependencies ──
MISSING_REQUIRED=()
MISSING_OPTIONAL=()

for cmd in bash python3 git curl flock sbatch squeue sacct; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_REQUIRED+=("$cmd")
    fi
done

# Check PyYAML
if ! python3 -c "import yaml" &>/dev/null 2>&1; then
    MISSING_REQUIRED+=("python3-yaml (PyYAML)")
fi

for cmd in claude; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING_OPTIONAL+=("$cmd")
    fi
done

# Check lmod
if ! type module &>/dev/null 2>&1; then
    MISSING_OPTIONAL+=("lmod (module command)")
fi

if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
    echo "ERROR: Missing required dependencies:"
    for dep in "${MISSING_REQUIRED[@]}"; do
        echo "  - $dep"
    done
    exit 1
fi

if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    echo "Note: Optional dependencies not found (some features may be limited):"
    for dep in "${MISSING_OPTIONAL[@]}"; do
        echo "  - $dep"
    done
    echo ""
fi

echo "All required dependencies found."
echo ""

# ── Copy files (clone mode only) ──
if [[ "$MODE" == "clone" ]]; then
    echo "Installing files to $TARGET_DIR ..."
    mkdir -p "$TARGET_DIR"

    # Copy bin/ and lib/ (always overwrite — these are code)
    cp -r "$SCRIPT_DIR/bin" "$TARGET_DIR/"
    cp -r "$SCRIPT_DIR/lib" "$TARGET_DIR/"

    # Copy example configs (always overwrite examples)
    mkdir -p "$TARGET_DIR/etc"
    cp "$SCRIPT_DIR/etc/global.conf.example" "$TARGET_DIR/etc/"
    cp "$SCRIPT_DIR/etc/projects.conf.example" "$TARGET_DIR/etc/"

    # Copy install.sh itself
    cp "$SCRIPT_DIR/install.sh" "$TARGET_DIR/"
    chmod +x "$TARGET_DIR/install.sh"

    echo "Files installed."
    echo ""
fi

# ── Ensure bin/ scripts are executable ──
chmod +x "$TARGET_DIR/bin/"*.sh 2>/dev/null || true

# ── Create var/ directories ──
echo "Creating var/ directories ..."
mkdir -p "$TARGET_DIR/var/logs"
mkdir -p "$TARGET_DIR/var/state"
mkdir -p "$TARGET_DIR/var/runs"
echo "Done."
echo ""

# ── Configure etc/global.conf ──
CONF_FILE="$TARGET_DIR/etc/global.conf"
if [[ -f "$CONF_FILE" ]]; then
    echo "Configuration file already exists: $CONF_FILE"
    echo "Skipping interactive configuration. Edit manually if needed."
    echo ""
else
    echo "Setting up configuration ..."
    echo "Press Enter to accept defaults (shown in brackets)."
    echo ""

    read -rp "Slack webhook URL (leave empty to disable): " SLACK_WEBHOOK
    SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

    read -rp "Slack bot token (leave empty to disable): " SLACK_TOKEN
    SLACK_TOKEN="${SLACK_TOKEN:-}"

    read -rp "Slack channel ID (leave empty to disable): " SLACK_CHANNEL
    SLACK_CHANNEL="${SLACK_CHANNEL:-}"

    read -rp "Notification email (leave empty to disable): " EMAIL
    EMAIL="${EMAIL:-}"

    read -rp "SLURM partition for sentinel jobs [128x24]: " PARTITION
    PARTITION="${PARTITION:-128x24}"

    read -rp "SLURM time limit for sentinel jobs [00:30:00]: " TIME_LIMIT
    TIME_LIMIT="${TIME_LIMIT:-00:30:00}"

    read -rp "Max fix cycles before human intervention [3]: " MAX_FIX
    MAX_FIX="${MAX_FIX:-3}"

    mkdir -p "$(dirname "$CONF_FILE")"
    cat > "$CONF_FILE" <<EOF
# Autopilot Global Configuration

# Email for notifications (leave empty to disable)
AUTOPILOT_EMAIL="$EMAIL"

# Slack webhook URL for notifications
AUTOPILOT_SLACK_WEBHOOK="$SLACK_WEBHOOK"

# Slack Bot/User Token for file uploads (images, plots)
AUTOPILOT_SLACK_TOKEN="$SLACK_TOKEN"

# Slack channel ID for notifications
AUTOPILOT_SLACK_CHANNEL="$SLACK_CHANNEL"

# Maximum fix cycles before requiring human intervention
AUTOPILOT_MAX_FIX_CYCLES=$MAX_FIX

# Debug mode (set to 1 for verbose logging)
AUTOPILOT_DEBUG=0

# Default SLURM partition for sentinel jobs
AUTOPILOT_SENTINEL_PARTITION="$PARTITION"

# Default SLURM time limit for sentinel jobs
AUTOPILOT_SENTINEL_TIME="$TIME_LIMIT"
EOF

    echo ""
    echo "Configuration written to $CONF_FILE"
    echo ""
fi

# ── Set up cron ──
echo "Setting up cron job ..."
CRON_CMD="*/2 * * * * $TARGET_DIR/bin/autopilot-poll.sh >> $TARGET_DIR/var/logs/poll.log 2>&1"

# Check if autopilot-poll is already in crontab
EXISTING_CRON="$(crontab -l 2>/dev/null || true)"
if echo "$EXISTING_CRON" | grep -qF "autopilot-poll.sh"; then
    echo "Cron entry for autopilot-poll.sh already exists. Updating ..."
    # Remove old entry, add new one
    NEW_CRON="$(echo "$EXISTING_CRON" | grep -vF "autopilot-poll.sh")"
    if [[ -n "$NEW_CRON" ]]; then
        printf '%s\n%s\n' "$NEW_CRON" "$CRON_CMD" | crontab -
    else
        echo "$CRON_CMD" | crontab -
    fi
else
    # Append to existing crontab
    if [[ -n "$EXISTING_CRON" ]]; then
        printf '%s\n%s\n' "$EXISTING_CRON" "$CRON_CMD" | crontab -
    else
        echo "$CRON_CMD" | crontab -
    fi
fi

echo "Cron job installed: $CRON_CMD"
echo ""

# ── Summary ──
echo "============================================"
echo "  Autopilot installation complete!"
echo "============================================"
echo ""
echo "Installed to: $TARGET_DIR"
echo ""
echo "Next steps:"
echo "  1. Review/edit your config:"
echo "       \$EDITOR $TARGET_DIR/etc/global.conf"
echo ""
echo "  2. Register a project:"
echo "       $TARGET_DIR/bin/autopilot-register.sh <name> <git_url>"
echo ""
echo "  3. Check status:"
echo "       $TARGET_DIR/bin/autopilot-status.sh"
echo ""
echo "  4. The cron job polls every 2 minutes. Check logs at:"
echo "       $TARGET_DIR/var/logs/poll.log"
echo ""
