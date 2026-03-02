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
    printf "%.0f" "$used" > "${CONTEXT_FILE}.tmp" && mv "${CONTEXT_FILE}.tmp" "$CONTEXT_FILE"
fi

# Output statusbar text (same as original statusline-command.sh)
if [ -n "$used" ] && [ -n "$remaining" ]; then
    printf "Context: %.0f%% used (%.0f%% remaining) | %s" "$used" "$remaining" "$model"
else
    printf "%s" "$model"
fi
