#!/bin/sh
# statusline.sh — Claude Code statusLine hook
# Reads statusLine JSON from stdin, writes context_pct to session JSON,
# and outputs statusbar text for Claude Code's built-in display.

input=$(cat)

session_id=$(echo "$input" | jq -r '.session_id // empty')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
model=$(echo "$input" | jq -r '.model.display_name // empty')

# Update session JSON with context_pct if we have a session_id and usage data
if [ -n "$session_id" ] && [ -n "$used" ]; then
    SESSION_FILE="$HOME/.claude/monitor/sessions/${session_id}.json"
    if [ -f "$SESSION_FILE" ]; then
        pct=$(printf "%.0f" "$used")
        jq --argjson pct "$pct" '. + {context_pct: $pct}' "$SESSION_FILE" > "${SESSION_FILE}.tmp" \
            && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
    fi
fi

# Output statusbar text (same as original statusline-command.sh)
if [ -n "$used" ] && [ -n "$remaining" ]; then
    printf "Context: %.0f%% used (%.0f%% remaining) | %s" "$used" "$remaining" "$model"
else
    printf "%s" "$model"
fi
