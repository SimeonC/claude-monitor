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

# --- Atomic JSON update helper ---
# Reads file content into memory THEN pipes to jq, so concurrent invocations
# can't read a partially-replaced file. Uses mkdir as a portable spinlock.
# Usage: update_json_file <file> <jq_args...>
update_json_file() {
    local file="$1"; shift
    local lockdir="${file}.lock"
    # Spin-acquire lock (mkdir is atomic on POSIX)
    local i=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        i=$((i + 1))
        if [ "$i" -ge 50 ]; then
            # Stale lock — force break after 500ms
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || return 1
            break
        fi
        sleep 0.01
    done
    local content
    content=$(cat "$file" 2>/dev/null) || { rm -rf "$lockdir"; return 1; }
    if [ -z "$content" ]; then rm -rf "$lockdir"; return 1; fi
    local result
    result=$(echo "$content" | jq "$@") || { rm -rf "$lockdir"; return 1; }
    echo "$result" > "${file}.tmp" && mv "${file}.tmp" "$file"
    rm -rf "$lockdir"
}

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

# --- Detect --dangerously-skip-permissions flag ---
# Walk up process tree to first `claude` ancestor and check its args.
detect_skip_permissions() {
    local pid=$$
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] || [ "$pid" = "0" ] && break
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)
        if [ "$comm" = "claude" ]; then
            if ps -ww -o args= -p "$pid" 2>/dev/null | grep -q -- '--dangerously-skip-permissions'; then
                return 0
            fi
            return 1
        fi
    done
    return 1
}

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
                    update_json_file "$SUBAGENT_SESSION_FILE" --arg updated "$NOW" \
                        '.status = "idle" | .updated_at = $updated'
                elif [ "$NOTIF_TYPE" = "permission_prompt" ]; then
                    update_json_file "$SUBAGENT_SESSION_FILE" --arg updated "$NOW" \
                        '.status = "attention" | .updated_at = $updated'
                fi
            fi
            ;;
        PreToolUse|PostToolUse|PostToolUseFailure)
            if ensure_subagent_file; then
                update_json_file "$SUBAGENT_SESSION_FILE" --arg updated "$NOW" \
                    'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
            fi
            ;;
        Stop)
            if find_subagent_session_file && [ -f "$SUBAGENT_SESSION_FILE" ]; then
                rm -f "$SUBAGENT_SESSION_FILE"
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

# Helper: create session file if missing or corrupt (hooks bootstrap it on first event after monitor restart)
ensure_session_file() {
    # Check file exists AND has valid JSON (empty/corrupt files need recreation)
    if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ] && jq -e . "$SESSION_FILE" >/dev/null 2>&1; then
        return 0
    fi
    jq -n \
        --arg sid "$SESSION_ID" --arg status "idle" \
        --arg project "$PROJECT" --arg cwd "${CWD:-}" \
        --arg terminal "$TERM_APP" --arg term_sid "$TERM_SID" \
        --arg now "$NOW" \
        '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0}' \
        > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# Helper: backfill terminal info on existing session file (preserves all other fields)
backfill_terminal() {
    ensure_session_file
    [ -f "$SESSION_FILE" ] || return 0
    [ -z "$TERM_APP" ] && return 0
    update_json_file "$SESSION_FILE" \
        --arg updated "$NOW" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        '.updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end'
}

# Helper: mark stale session files for the same terminal tab as dead (different session_id)
cleanup_same_terminal() {
    [ -z "$TERM_SID" ] && return
    for f in "$SESSIONS_DIR"/*.json; do
        [ -f "$f" ] || continue
        local fid
        fid=$(basename "$f" .json)
        [ "$fid" = "$SESSION_ID" ] && continue
        # Delete if same terminal_session_id (stale session in this tab)
        if jq -e --arg tid "$TERM_SID" '.terminal_session_id == $tid' "$f" >/dev/null 2>&1; then
            rm -f "$f" "$SESSIONS_DIR/${fid}.context" "$SESSIONS_DIR/${fid}.model"
        fi
    done
}

# Helper: any non-dead status → working when user/tool activity happens.
# PreToolUse fires after the user approves a permission prompt, so this clears attention.
set_working() {
    ensure_session_file
    [ -f "$SESSION_FILE" ] || return 0
    update_json_file "$SESSION_FILE" \
        --arg updated "$NOW" \
        'if .status == "dead" then .updated_at = $updated elif .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
}

# --- Handle events ---
case "$EVENT" in
    SessionStart)
        cleanup_same_terminal
        # Detect --dangerously-skip-permissions once at session start
        if detect_skip_permissions; then
            SKIP_PERMS=true
        else
            SKIP_PERMS=false
        fi
        if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ]; then
            # Session file exists — backfill terminal and reboot if dead
            backfill_terminal
            CURRENT_STATUS=$(jq -r '.status // ""' "$SESSION_FILE" 2>/dev/null)
            if [ "$CURRENT_STATUS" = "dead" ]; then
                update_json_file "$SESSION_FILE" \
                    --arg status "idle" \
                    --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated'
            fi
            # Persist skip_permissions flag (clear if not detected)
            if [ "$SKIP_PERMS" = "true" ]; then
                update_json_file "$SESSION_FILE" '.skip_permissions = true'
            else
                update_json_file "$SESSION_FILE" 'del(.skip_permissions)'
            fi
        else
            # New session — create file with "starting" status
            if [ "$SKIP_PERMS" = "true" ]; then
                jq -n \
                    --arg sid "$SESSION_ID" \
                    --arg status "starting" \
                    --arg project "$PROJECT" \
                    --arg cwd "${CWD:-}" \
                    --arg terminal "$TERM_APP" \
                    --arg term_sid "$TERM_SID" \
                    --arg now "$NOW" \
                    '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0, skip_permissions: true}' \
                    > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
            else
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
        fi
        ;;

    Stop)
        ensure_session_file
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg status "idle" \
                --arg updated "$NOW" \
                'if .status == "dead" then . else .status = $status | .updated_at = $updated end'
        fi
        ;;

    Notification)
        NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
        ensure_session_file
        if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
            # idle_prompt means Claude is at the input prompt — set idle
            if [ -f "$SESSION_FILE" ]; then
                update_json_file "$SESSION_FILE" \
                    --arg status "idle" \
                    --arg updated "$NOW" \
                    'if .status == "dead" then . else .status = $status | .updated_at = $updated end'
            fi
            exit 0
        fi
        # Non-idle notification = needs attention (permission prompt, etc.)
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg status "attention" \
                --arg updated "$NOW" \
                --arg terminal "$TERM_APP" \
                --arg term_sid "$TERM_SID" \
                'if .status == "dead" then . else .status = $status | .updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end end'
        fi
        ;;

    SessionEnd)
        # Session ended — delete session and sidecar files
        rm -f "$SESSION_FILE" "$SESSIONS_DIR/${SESSION_ID}.context" "$SESSIONS_DIR/${SESSION_ID}.model"
        ;;

    SubagentStart)
        # Sub-agent spawned — update parent status to working
        backfill_terminal
        set_working
        ;;

    SubagentStop)
        # Sub-agent finished — delete its session file, update parent to working.
        # Don't override "idle": Stop may have already fired before this SubagentStop.
        AGENT_TRANSCRIPT=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')
        if [ -n "$AGENT_TRANSCRIPT" ]; then
            local_filename=$(basename "$AGENT_TRANSCRIPT" .jsonl)
            rm -f "$SESSIONS_DIR/sub-${local_filename}.json"
        fi
        backfill_terminal
        ensure_session_file
        [ -f "$SESSION_FILE" ] || exit 0
        update_json_file "$SESSION_FILE" \
            --arg updated "$NOW" \
            'if .status == "dead" or .status == "idle" then .updated_at = $updated elif .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
        ;;

    UserPromptSubmit|PostToolUse|PostToolUseFailure)
        # User submitted prompt or tool completed — clear attention and set working.
        # PostToolUse/PostToolUseFailure means user answered any permission prompt; UserPromptSubmit means user is active.
        ensure_session_file
        backfill_terminal
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg updated "$NOW" \
                'if .status == "dead" then . else .status = "working" | .updated_at = $updated end'
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
