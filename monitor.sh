#!/bin/bash
# ~/.claude/hooks/monitor.sh
# Claude Code lifecycle hook — writes session JSON + triggers TTS
# Called by hook events: SessionStart, UserPromptSubmit, Stop, PreToolUse, PostToolUse, Notification, SessionEnd
#
# Usage: monitor.sh [event]
# Receives hook JSON on stdin (event auto-detected from hook_event_name if arg omitted)

set -euo pipefail

INPUT=$(cat)

# Event from arg, or fall back to hook_event_name in the JSON input
EVENT="${1:-$(echo "$INPUT" | jq -r '.hook_event_name // "unknown"')}"

# --- Paths ---
MONITOR_DIR="$HOME/.claude/monitor"
SESSIONS_DIR="$MONITOR_DIR/sessions"
CONFIG_FILE="$MONITOR_DIR/config.json"

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

# --- TTS announcement ---
announce() {
    local msg="$1"
    local provider voice rate

    # Read config
    if [ ! -f "$CONFIG_FILE" ]; then
        return
    fi

    provider=$(jq -r '.tts_provider // "say"' "$CONFIG_FILE")
    local volume
    volume=$(jq -r '.announce.volume // 0.5' "$CONFIG_FILE")

    if [ "$provider" = "elevenlabs" ]; then
        local env_file model stability similarity
        env_file=$(jq -r '.elevenlabs.env_file // empty' "$CONFIG_FILE")
        env_file="${env_file/#\~/$HOME}"
        model=$(jq -r '.elevenlabs.model // "eleven_multilingual_v2"' "$CONFIG_FILE")
        stability=$(jq -r '.elevenlabs.stability // 0.5' "$CONFIG_FILE")
        similarity=$(jq -r '.elevenlabs.similarity_boost // 0.75' "$CONFIG_FILE")

        if [ -f "$env_file" ]; then
            set -a; source "$env_file"; set +a
        fi

        local config_voice_id
        config_voice_id=$(jq -r '.elevenlabs.voice_id // empty' "$CONFIG_FILE")
        if [ -n "$config_voice_id" ]; then
            ELEVENLABS_VOICE_ID="$config_voice_id"
        fi

        if [ -n "${ELEVENLABS_API_KEY:-}" ] && [ -n "${ELEVENLABS_VOICE_ID:-}" ]; then
            local temp_audio="/tmp/claude_monitor_tts_$$.mp3"
            local json_payload
            json_payload=$(python3 -c "
import json, sys
print(json.dumps({
    'text': sys.argv[1],
    'model_id': sys.argv[2],
    'voice_settings': {'stability': float(sys.argv[3]), 'similarity_boost': float(sys.argv[4])}
}))
" "$msg" "$model" "$stability" "$similarity")

            local http_code
            http_code=$(curl -s -w '%{http_code}' -X POST \
                "https://api.elevenlabs.io/v1/text-to-speech/$ELEVENLABS_VOICE_ID" \
                -H "xi-api-key: $ELEVENLABS_API_KEY" \
                -H "Content-Type: application/json" \
                -d "$json_payload" \
                -o "$temp_audio")

            if [ "$http_code" = "200" ] && [ -s "$temp_audio" ]; then
                afplay -v "$volume" "$temp_audio" &
                disown 2>/dev/null
                (sleep 30 && rm -f "$temp_audio") &
                disown 2>/dev/null
            else
                rm -f "$temp_audio"
                say -v "Samantha" -r 200 "$msg" &
                disown 2>/dev/null
            fi
        else
            say -v "Samantha" -r 200 "$msg" &
            disown 2>/dev/null
        fi
    else
        voice=$(jq -r '.say.voice // "Samantha"' "$CONFIG_FILE")
        rate=$(jq -r '.say.rate // 200' "$CONFIG_FILE")
        # osascript say supports volume 0.0-1.0
        osascript -e "say \"${msg}\" using \"${voice}\" speaking rate ${rate} volume ${volume}" &
        disown 2>/dev/null
    fi
}

# --- Should we announce this event? ---
should_announce() {
    local event_type="$1"
    if [ ! -f "$CONFIG_FILE" ]; then
        return 1
    fi

    # Master toggle
    jq -e '.announce.enabled == true' "$CONFIG_FILE" >/dev/null 2>&1 || return 1

    case "$event_type" in
        done)     jq -e '.announce.on_done == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        attention) jq -e '.announce.on_attention == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        start)    jq -e '.announce.on_start == true' "$CONFIG_FILE" >/dev/null 2>&1 ;;
        *)        return 1 ;;
    esac
}

# --- Detect terminal once for all events ---
TERM_INFO=$(detect_terminal)
TERM_APP=$(echo "$TERM_INFO" | cut -d'|' -f1)
TERM_SID=$(echo "$TERM_INFO" | cut -d'|' -f2)

# Helper: backfill terminal info + update status on existing session file
update_session() {
    local new_status="$1"
    jq \
        --arg status "$new_status" \
        --arg updated "$NOW" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        '.status = $status | .updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end' \
        "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# Helper: create new session file
create_session() {
    local new_status="$1"
    local prompt="${2:-}"
    jq -n \
        --arg sid "$SESSION_ID" \
        --arg status "$new_status" \
        --arg project "$PROJECT" \
        --arg cwd "${CWD:-}" \
        --arg terminal "$TERM_APP" \
        --arg term_sid "$TERM_SID" \
        --arg started "$NOW" \
        --arg updated "$NOW" \
        --arg prompt "$prompt" \
        '{session_id:$sid,status:$status,project:$project,cwd:$cwd,terminal:$terminal,terminal_session_id:$term_sid,started_at:$started,updated_at:$updated,last_prompt:$prompt}' \
        > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
}

# --- Handle events ---
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

case "$EVENT" in
    SessionStart)
        SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"')
        case "$SOURCE" in
            startup)
                cleanup_same_terminal
                create_session "starting"
                if should_announce start; then
                    announce "$PROJECT_NAME starting" &
                fi
                ;;
            resume)
                cleanup_same_terminal
                if [ -f "$SESSION_FILE" ]; then
                    update_session "starting"
                else
                    create_session "starting"
                fi
                if should_announce start; then
                    announce "$PROJECT_NAME starting" &
                fi
                ;;
            *)
                # Unknown source (e.g. /clear, /compact) — session is idle, mark done
                if [ -f "$SESSION_FILE" ]; then
                    update_session "done"
                else
                    create_session "done"
                fi
                ;;
        esac
        ;;

    UserPromptSubmit)
        PROMPT_TEXT=$(echo "$INPUT" | jq -r '.prompt // empty' | head -c 200)
        if [ -f "$SESSION_FILE" ]; then
            # Single atomic write: status + prompt + terminal backfill
            jq \
                --arg status "working" \
                --arg updated "$NOW" \
                --arg prompt "$PROMPT_TEXT" \
                --arg terminal "$TERM_APP" \
                --arg term_sid "$TERM_SID" \
                '.status = $status | .updated_at = $updated | .last_prompt = $prompt | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end' \
                "$SESSION_FILE" > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
        else
            create_session "working" "$PROMPT_TEXT"
        fi
        ;;

    Stop)
        if [ -f "$SESSION_FILE" ]; then
            update_session "done"
        else
            create_session "done"
        fi
        if should_announce done; then
            announce "$PROJECT_NAME done" &
        fi
        ;;

    PreToolUse|PostToolUse)
        # Claude is actively working — PreToolUse fires earliest, PostToolUse
        # catches the resume after a permission prompt is accepted
        if [ -f "$SESSION_FILE" ]; then
            update_session "working"
        fi
        ;;

    Notification)
        NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
        # idle_prompt means Claude is waiting for input — that's "done", not "attention"
        # But don't override "working" or "attention" — those mean a tool is running or
        # a permission prompt is active. Stop/PostToolUse handle those transitions.
        if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
            if [ -f "$SESSION_FILE" ]; then
                CURRENT_STATUS=$(jq -r '.status // "unknown"' "$SESSION_FILE")
                if [ "$CURRENT_STATUS" = "working" ] || [ "$CURRENT_STATUS" = "attention" ]; then
                    exit 0
                fi
                update_session "done"
            else
                create_session "done"
            fi
            if should_announce done; then
                announce "$PROJECT_NAME done" &
            fi
            exit 0
        fi
        if [ -f "$SESSION_FILE" ]; then
            update_session "attention"
        else
            create_session "attention"
        fi
        if should_announce attention; then
            announce "$PROJECT_NAME needs attention" &
        fi
        ;;

    SessionEnd)
        # Mark done instead of deleting — /clear fires SessionEnd then SessionStart,
        # so deleting would make it look like the session closed.
        # The TTY liveness pruner in the Swift app handles truly dead sessions.
        if [ -f "$SESSION_FILE" ]; then
            update_session "done"
        fi
        ;;
esac

exit 0
