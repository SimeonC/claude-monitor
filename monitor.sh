#!/bin/bash
# ~/.claude/hooks/monitor.sh
# Claude Code lifecycle hook — backfills terminal info + handles attention status + TTS
# Session creation and status (working/done) are handled by the Swift app's JSONL scanner.
#
# Usage: monitor.sh [event]
# Receives hook JSON on stdin

set -euo pipefail

INPUT=$(cat)

# Event from arg, or fall back to hook_event_name in the JSON input
EVENT="${1:-$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"')}"

# --- Paths ---
MONITOR_DIR="$HOME/.claude/monitor"
SESSIONS_DIR="$MONITOR_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

# --- Extract context from hook JSON ---
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Need a session ID to do anything useful
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

SESSION_FILE="$SESSIONS_DIR/${SESSION_ID}.json"
PROJECT=$(basename "${CWD:-unknown}")
PROJECT_NAME=$(echo "$PROJECT" | sed 's/[-_]/ /g')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- Sub-agent detection ---
# Skip hooks fired by sub-agents (team members, Task tool agents).
# Process tree: monitor.sh → sh → claude (this session) → ... → claude (parent session)
# If we find TWO claude ancestors, we're a sub-agent.
is_subagent() {
    local pid=$$ claude_count=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] || [ "$pid" = "0" ] && break
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)
        if [ "$comm" = "claude" ]; then
            claude_count=$((claude_count + 1))
            [ "$claude_count" -ge 2 ] && return 0
        fi
    done
    return 1
}

if is_subagent; then
    exit 0
fi

# --- Detect terminal + session ID for click-to-switch ---
detect_terminal() {
    local term_app=""
    local term_session_id=""

    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        echo "iterm2|$ITERM_SESSION_ID"
        return
    fi

    # Walk up process tree to find a parent with a real TTY
    local pid=$$
    local tty_name=""
    for _ in 1 2 3 4 5; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] && break
        tty_name=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$tty_name" ] && [ "$tty_name" != "??" ]; then
            break
        fi
    done

    if [ -n "${GHOSTTY_RESOURCES_DIR:-}" ]; then
        echo "ghostty|/dev/$tty_name"
        return
    fi

    if [ -n "$tty_name" ] && [ "$tty_name" != "??" ]; then
        term_app="terminal"
        term_session_id="/dev/$tty_name"
    fi

    echo "$term_app|$term_session_id"
}

# --- Detect terminal once for all events ---
TERM_INFO=$(detect_terminal)
TERM_APP=$(echo "$TERM_INFO" | cut -d'|' -f1)
TERM_SID=$(echo "$TERM_INFO" | cut -d'|' -f2)

# Helper: backfill terminal info on existing session file (preserves all other fields)
backfill_terminal() {
    [ -f "$SESSION_FILE" ] || return 0
    [ -z "$TERM_APP" ] && return 0
    jq \
        --arg updated "$NOW" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        '.updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end' \
        "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# Helper: remove stale session files for the same terminal tab (different session_id)
cleanup_same_terminal() {
    [ -z "$TERM_SID" ] && return
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        local fid
        fid=$(basename "$f" .json)
        [ "$fid" = "$SESSION_ID" ] && continue
        # Remove if same terminal_session_id
        if jq -e --arg tid "$TERM_SID" '.terminal_session_id == $tid' "$f" >/dev/null 2>&1; then
            rm -f "$f"
        fi
    done
}

# Helper: any non-working status → working when user/tool activity happens
set_working() {
    [ -f "$SESSION_FILE" ] || return 0
    jq \
        --arg updated "$NOW" \
        'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end' \
        "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# --- Handle events ---
case "$EVENT" in
    SessionStart)
        cleanup_same_terminal
        if [ -f "$SESSION_FILE" ]; then
            # Session file exists — backfill terminal and reboot if shutting_down
            backfill_terminal
            CURRENT_STATUS=$(jq -r '.status // ""' "$SESSION_FILE")
            if [ "$CURRENT_STATUS" = "shutting_down" ]; then
                jq \
                    --arg status "starting" \
                    --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated' \
                    "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
            fi
        else
            # New session — create file with "starting" status
            jq -n \
                --arg sid "$SESSION_ID" \
                --arg status "starting" \
                --arg project "$PROJECT" \
                --arg cwd "${CWD:-}" \
                --arg terminal "$TERM_APP" \
                --arg term_sid "$TERM_SID" \
                --arg now "$NOW" \
                '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0}' \
                > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
        ;;

    Stop)
        if [ -f "$SESSION_FILE" ]; then
            jq \
                --arg status "idle" \
                --arg updated "$NOW" \
                '.status = $status | .updated_at = $updated' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
        ;;

    Notification)
        NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
        if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
            # idle_prompt means Claude is at the input prompt — set idle
            if [ -f "$SESSION_FILE" ]; then
                jq \
                    --arg status "idle" \
                    --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated' \
                    "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
            fi
            exit 0
        fi
        # Non-idle notification = needs attention (permission prompt, etc.)
        if [ -f "$SESSION_FILE" ]; then
            jq \
                --arg status "attention" \
                --arg updated "$NOW" \
                --arg terminal "$TERM_APP" \
                --arg term_sid "$TERM_SID" \
                '.status = $status | .updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
        ;;

    SessionEnd)
        # Session is shutting down — backfill terminal info and mark as shutting_down
        backfill_terminal
        if [ -f "$SESSION_FILE" ]; then
            jq \
                --arg status "shutting_down" \
                --arg updated "$NOW" \
                '.status = $status | .updated_at = $updated' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
        ;;

    *)
        # All other events (UserPromptSubmit, PreToolUse, PostToolUse):
        # Backfill terminal info and set working (user/tool activity = actively processing)
        backfill_terminal
        set_working
        ;;
esac

exit 0
