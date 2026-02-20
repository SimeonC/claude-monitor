#!/bin/bash
# Update Claude Monitor from the repo working copy
# Copies files, updates hooks in settings.json, rebuilds, and restarts

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR_DIR="$HOME/.claude/monitor"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo "Updating Claude Monitor from $REPO_DIR"

# Ensure target dirs exist
mkdir -p "$MONITOR_DIR/sessions" "$HOOKS_DIR"

# --- Copy files ---
cp "$REPO_DIR/claude_monitor.swift" "$MONITOR_DIR/claude_monitor.swift"
cp "$REPO_DIR/build.sh"             "$MONITOR_DIR/build.sh"
cp "$REPO_DIR/monitor.sh"           "$HOOKS_DIR/monitor.sh"

# config.json — only copy if not already present (don't overwrite user config)
if [ ! -f "$MONITOR_DIR/config.json" ]; then
    cp "$REPO_DIR/config.json" "$MONITOR_DIR/config.json"
    echo "Created default config.json"
else
    echo "config.json already exists, skipping (won't overwrite your settings)"
fi

chmod +x "$MONITOR_DIR/build.sh" "$HOOKS_DIR/monitor.sh"

echo "Files copied."

# --- Update hooks in settings.json ---
DESIRED_HOOKS="$REPO_DIR/hooks.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    # No settings file — create one with just hooks
    jq -n --slurpfile hooks "$DESIRED_HOOKS" '{hooks: $hooks[0]}' > "$SETTINGS_FILE"
    echo "Created $SETTINGS_FILE with monitor hooks."
else
    # Merge: overwrite monitor hook events, preserve everything else
    # Strategy: for each event in hooks.json, replace that key in settings.hooks.
    # Any existing hook events NOT in hooks.json are left untouched.
    BEFORE=$(jq -r '.hooks // {} | keys[]' "$SETTINGS_FILE" 2>/dev/null | sort)

    jq --slurpfile desired "$DESIRED_HOOKS" '
        .hooks = ((.hooks // {}) * $desired[0])
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

    AFTER=$(jq -r '.hooks | keys[]' "$SETTINGS_FILE" | sort)

    # Report what changed
    ADDED=$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))
    if [ -n "$ADDED" ]; then
        echo "Added hook events: $ADDED"
    fi
    echo "Hooks in settings.json updated."
fi

# --- Build and restart ---
"$MONITOR_DIR/build.sh"
