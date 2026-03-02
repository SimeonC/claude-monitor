#!/bin/sh
# statusline.sh — Claude Code statusLine hook
# Reads statusLine JSON from stdin, writes context_pct to sidecar file,
# and outputs statusbar text for Claude Code's built-in display.

input=$(cat)

session_id=$(echo "$input" | jq -r '.session_id // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Write context_pct to sidecar file (avoids TOCTOU race with monitor.sh on session JSON)
if [ -n "$session_id" ] && [ -n "$used" ]; then
    CONTEXT_FILE="$HOME/.claude/monitor/sessions/${session_id}.context"
    SESSION_FILE="$HOME/.claude/monitor/sessions/${session_id}.json"
    new_pct=$(printf "%.0f" "$used")

    # Detect context reset (/clear): context drops from >10% to <5%
    if [ -f "$CONTEXT_FILE" ] && [ -f "$SESSION_FILE" ]; then
        old_pct=$(cat "$CONTEXT_FILE" 2>/dev/null || echo "0")
        if [ "$old_pct" -gt 10 ] 2>/dev/null && [ "$new_pct" -lt 5 ] 2>/dev/null; then
            NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq --arg now "$NOW" \
                '.started_at = $now | .updated_at = $now | if .status != "dead" then .status = "idle" else . end' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
    fi

    printf "%s" "$new_pct" > "${CONTEXT_FILE}.tmp" && mv "${CONTEXT_FILE}.tmp" "$CONTEXT_FILE"

    # Write model name to sidecar file
    if [ -n "$model" ]; then
        MODEL_FILE="$HOME/.claude/monitor/sessions/${session_id}.model"
        printf "%s" "$model" > "${MODEL_FILE}.tmp" && mv "${MODEL_FILE}.tmp" "$MODEL_FILE"
    fi
fi

# Output statusbar text (same as original statusline-command.sh)
if [ -n "$used" ] && [ -n "$remaining" ]; then
    printf "Context: %.0f%% used (%.0f%% remaining) | %s" "$used" "$remaining" "$model"
else
    printf "%s" "$model"
fi
