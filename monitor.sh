#!/bin/bash
# ~/.claude/hooks/monitor.sh
# Claude Code lifecycle hook — backfills terminal info + handles attention status + TTS
# Session creation and status (working/done) are handled by the Swift app's JSONL scanner.
#
# Usage: monitor.sh [event]
# Receives hook JSON on stdin

set -uo pipefail

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
    IS_SUBAGENT=true
else
    IS_SUBAGENT=false
fi

# --- Sub-agent session file helpers ---
# Extract transcript_path from hook JSON; derive sub-agent ID and parent session ID.
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')

find_subagent_session_file() {
    # Only works if transcript_path contains /subagents/
    if [ -z "$TRANSCRIPT_PATH" ] || ! echo "$TRANSCRIPT_PATH" | grep -q '/subagents/'; then
        return 1
    fi
    # Extract filename without .jsonl as sub-agent ID
    local filename
    filename=$(basename "$TRANSCRIPT_PATH" .jsonl)
    SUBAGENT_ID="$filename"
    SUBAGENT_SESSION_FILE="$SESSIONS_DIR/sub-${SUBAGENT_ID}.json"
    # Parent session ID = directory name two levels up from the subagent file
    # e.g. .../projects/<project>/<parentSid>/subagents/<file>.jsonl
    local parent_dir
    parent_dir=$(dirname "$(dirname "$TRANSCRIPT_PATH")")
    SUBAGENT_PARENT_SID=$(basename "$parent_dir")
    return 0
}

# Helper: create sub-agent session file if it doesn't exist (self-registration)
ensure_subagent_file() {
    find_subagent_session_file || return 1
    if [ ! -f "$SUBAGENT_SESSION_FILE" ]; then
        jq -n \
            --arg sid "sub-${SUBAGENT_ID}" \
            --arg status "working" \
            --arg project "$PROJECT" \
            --arg cwd "${CWD:-}" \
            --arg parent "$SUBAGENT_PARENT_SID" \
            --arg now "$NOW" \
            '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: "", terminal_session_id: "", started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0, parent_session_id: $parent}' \
            > "${SUBAGENT_SESSION_FILE}.tmp" && mv "${SUBAGENT_SESSION_FILE}.tmp" "$SUBAGENT_SESSION_FILE"
    fi
    return 0
}

# --- Sub-agent event handling ---
if [ "$IS_SUBAGENT" = "true" ]; then
    case "$EVENT" in
        Notification)
            NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
            if ensure_subagent_file; then
                if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
                    jq --arg updated "$NOW" \
                        'if .status == "dead" then . else .status = "idle" | .updated_at = $updated end' \
                        "$SUBAGENT_SESSION_FILE" > "${SUBAGENT_SESSION_FILE}.tmp" && mv "${SUBAGENT_SESSION_FILE}.tmp" "$SUBAGENT_SESSION_FILE"
                elif [ "$NOTIF_TYPE" = "permission_prompt" ]; then
                    jq --arg updated "$NOW" \
                        'if .status == "dead" then . else .status = "attention" | .updated_at = $updated end' \
                        "$SUBAGENT_SESSION_FILE" > "${SUBAGENT_SESSION_FILE}.tmp" && mv "${SUBAGENT_SESSION_FILE}.tmp" "$SUBAGENT_SESSION_FILE"
                fi
            fi
            ;;
        PreToolUse|PostToolUse|PostToolUseFailure)
            if ensure_subagent_file; then
                jq --arg updated "$NOW" \
                    'if .status == "dead" then .updated_at = $updated elif .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end' \
                    "$SUBAGENT_SESSION_FILE" > "${SUBAGENT_SESSION_FILE}.tmp" && mv "${SUBAGENT_SESSION_FILE}.tmp" "$SUBAGENT_SESSION_FILE"
            fi
            ;;
        Stop)
            if ensure_subagent_file; then
                jq --arg updated "$NOW" \
                    'if .status == "dead" then . else .status = "idle" | .updated_at = $updated end' \
                    "$SUBAGENT_SESSION_FILE" > "${SUBAGENT_SESSION_FILE}.tmp" && mv "${SUBAGENT_SESSION_FILE}.tmp" "$SUBAGENT_SESSION_FILE"
            fi
            ;;
        *)
            # All other sub-agent events: ignore
            ;;
    esac
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
        if [ -n "${CLAUDE_MONITOR_ID:-}" ]; then
            echo "ghostty|$CLAUDE_MONITOR_ID"
        else
            echo "ghostty|/dev/$tty_name"
        fi
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

# Helper: mark stale session files for the same terminal tab as dead (different session_id)
cleanup_same_terminal() {
    [ -z "$TERM_SID" ] && return
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        local fid
        fid=$(basename "$f" .json)
        [ "$fid" = "$SESSION_ID" ] && continue
        # Mark as dead if same terminal_session_id
        if jq -e --arg tid "$TERM_SID" '.terminal_session_id == $tid' "$f" >/dev/null 2>&1; then
            jq '.status = "dead"' "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        fi
    done
}

# Helper: any non-dead status → working when user/tool activity happens.
# PreToolUse fires after the user approves a permission prompt, so this clears attention.
set_working() {
    [ -f "$SESSION_FILE" ] || return 0
    jq \
        --arg updated "$NOW" \
        'if .status == "dead" then .updated_at = $updated elif .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end' \
        "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# --- Handle events ---
case "$EVENT" in
    SessionStart)
        cleanup_same_terminal
        if [ -f "$SESSION_FILE" ]; then
            # Session file exists — backfill terminal and reboot if shutting_down/dead
            backfill_terminal
            CURRENT_STATUS=$(jq -r '.status // ""' "$SESSION_FILE")
            if [ "$CURRENT_STATUS" = "shutting_down" ] || [ "$CURRENT_STATUS" = "dead" ]; then
                jq \
                    --arg status "idle" \
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
                'if .status == "dead" then . else .status = $status | .updated_at = $updated end' \
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
                    'if .status == "dead" then . else .status = $status | .updated_at = $updated end' \
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
                'if .status == "dead" then . else .status = $status | .updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end end' \
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

    SubagentStart)
        # Sub-agent spawned — update parent status to working
        backfill_terminal
        set_working
        ;;

    SubagentStop)
        # Sub-agent finished — update parent status to working
        # Also mark the sub-agent's session file as dead if we can find it
        AGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')
        if [ -n "$AGENT_TRANSCRIPT" ]; then
            local_filename=$(basename "$AGENT_TRANSCRIPT" .jsonl)
            local_subagent_file="$SESSIONS_DIR/sub-${local_filename}.json"
            if [ -f "$local_subagent_file" ]; then
                jq --arg updated "$NOW" '.status = "dead" | .updated_at = $updated' \
                    "$local_subagent_file" > "${local_subagent_file}.tmp" && mv "${local_subagent_file}.tmp" "$local_subagent_file"
            fi
        fi
        backfill_terminal
        set_working
        ;;

    UserPromptSubmit|PostToolUse|PostToolUseFailure)
        # User submitted prompt or tool completed — clear attention and set working.
        # PostToolUse/PostToolUseFailure means user answered any permission prompt; UserPromptSubmit means user is active.
        backfill_terminal
        if [ -f "$SESSION_FILE" ]; then
            jq \
                --arg updated "$NOW" \
                'if .status == "dead" then . else .status = "working" | .updated_at = $updated end' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        fi
        ;;

    *)
        # All other events (PreToolUse, etc.):
        # Backfill terminal info and set working (clears attention — PreToolUse means user approved)
        backfill_terminal
        set_working
        ;;
esac

exit 0
