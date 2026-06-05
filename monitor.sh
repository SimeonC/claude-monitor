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
MONITOR_DIR="$HOME/.claude-monitor"
SESSIONS_DIR="$MONITOR_DIR/sessions"
mkdir -p "$SESSIONS_DIR"

# Trace: full hook capture to hook-trace.log — only for T3 Code sessions (debug switch)
# if [ "${__CFBundleIdentifier:-}" = "com.t3tools.t3code" ]; then
#     {
#         TRACE_SID=$(echo "$INPUT" | jq -r '.session_id // "unknown"' 2>/dev/null)
#         echo "=== $(date -u +%FT%TZ) EVENT=$EVENT SID=$TRACE_SID ==="
#         echo "-- full env --"
#         env | sort
#         echo "-- env (T3/Electron/Claude vars) --"
#         env | grep -E '^(CLAUDE_|ELECTRON_|__CFBundleIdentifier|TERM|ITERM|GHOSTTY|CMUX)' | sort
#         echo "-- stdin JSON --"
#         echo "$INPUT" | jq -c '.' 2>/dev/null || echo "$INPUT"
#         echo
#     } >> "$MONITOR_DIR/hook-trace.log" 2>/dev/null
# fi

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

# Opt-out: process sets NO_CLAUDE_MONITOR=true to suppress all monitor recording.
if [ "${NO_CLAUDE_MONITOR:-}" = "true" ]; then
    exit 0
fi

# --- Extract context from hook JSON ---
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PERMISSION_MODE=$(echo "$INPUT" | jq -r '.permission_mode // empty')

# Skip T3 Code probe sessions launched at $HOME with the SDK entrypoint — these are
# ephemeral (<1s) processes T3 spawns for auth/state checks, not user-facing sessions.
if [ "${__CFBundleIdentifier:-}" = "com.t3tools.t3code" ] \
   && [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "sdk-ts" ] \
   && [ "$CWD" = "$HOME" ]; then
    exit 0
fi

# Need a session ID to do anything useful
if [ -z "$SESSION_ID" ]; then
    exit 0
fi

SESSION_FILE="$SESSIONS_DIR/${SESSION_ID}.json"
MONITORS_FILE="$SESSIONS_DIR/${SESSION_ID}.monitors"

# Derive project label. T3 Code worktrees live at ~/.t3/worktrees/<title>/<sha-dir>;
# strip to the <title> segment. Everything else falls back to basename(cwd).
derive_project() {
    local cwd="${1:-unknown}"
    case "$cwd" in
        "$HOME/.t3/worktrees/"*)
            local rest="${cwd#$HOME/.t3/worktrees/}"
            printf '%s' "${rest%%/*}"
            ;;
        *)
            basename "$cwd"
            ;;
    esac
}
PROJECT=$(derive_project "${CWD:-unknown}")
PROJECT_NAME=$(echo "$PROJECT" | sed 's/[-_]/ /g')
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# --- T3 utility session detection ---
# T3 Code spawns internal sdk-cli processes (for thread title, git branch name, etc.)
# in the same worktree as the main chat. Each gets its own session_id and would otherwise
# appear as a separate row. Attribute them to the parent chat via parent_session_id so
# the Swift aggregator hides them and bumps agent_count.
is_t3_utility() {
    [ "${__CFBundleIdentifier:-}" = "com.t3tools.t3code" ] \
        && [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "sdk-cli" ]
}

resolve_t3_parent_sid() {
    T3_PARENT_SID=""
    [ -d "$SESSIONS_DIR" ] || return 0
    # Find the most recently-updated t3code session in this cwd that isn't us and
    # isn't itself a linked child. Guard against no-match globs.
    shopt -s nullglob 2>/dev/null || true
    local files=("$SESSIONS_DIR"/*.json)
    [ "${#files[@]}" -gt 0 ] || return 0
    T3_PARENT_SID=$(jq -rs --arg cwd "$CWD" --arg self "$SESSION_ID" \
        '[.[] | select(.terminal == "t3code" and .cwd == $cwd and .session_id != $self and (.parent_session_id // "") == "")]
         | sort_by(.updated_at) | reverse | .[0].session_id // empty' \
        "${files[@]}" 2>/dev/null)
}

if is_t3_utility; then
    resolve_t3_parent_sid
    if [ -n "$T3_PARENT_SID" ]; then
        case "$EVENT" in
            SessionStart)
                jq -n \
                    --arg sid "$SESSION_ID" \
                    --arg status "working" \
                    --arg project "$PROJECT" \
                    --arg cwd "${CWD:-}" \
                    --arg parent "$T3_PARENT_SID" \
                    --arg now "$NOW" \
                    '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: "t3code", terminal_session_id: "", started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0, parent_session_id: $parent}' \
                    > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
                ;;
            UserPromptSubmit)
                PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' | head -c 200)
                if [ -f "$SESSION_FILE" ]; then
                    update_json_file "$SESSION_FILE" --arg updated "$NOW" --arg prompt "$PROMPT" \
                        'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end | if $prompt != "" then .last_prompt = $prompt else . end'
                fi
                ;;
            PreToolUse)
                TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
                if [ -f "$SESSION_FILE" ]; then
                    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            '.status = "attention" | .updated_at = $updated'
                    else
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
                    fi
                fi
                ;;
            PostToolUse|PostToolUseFailure)
                if [ -f "$SESSION_FILE" ]; then
                    update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                        'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
                fi
                ;;
            Stop|SessionEnd)
                rm -f "$SESSION_FILE" "$SESSIONS_DIR/${SESSION_ID}.context" "$SESSIONS_DIR/${SESSION_ID}.model"
                ;;
            *)
                ;;
        esac
        exit 0
    fi
    # No parent found (race at startup) — fall through to normal T3 flow.
fi

# --- Team agent detection ---
# Team agents run in separate tmux sessions (not child processes of the team lead).
# Walk process tree to the first `claude` ancestor and check for --parent-session-id.
detect_parent_session_id() {
    local pid=$$
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] || [ "$pid" = "0" ] && break
        local args
        args=$(ps -ww -o args= -p "$pid" 2>/dev/null)
        if echo "$args" | grep -q -- '--parent-session-id'; then
            PARENT_SESSION_ID=$(echo "$args" | sed -n 's/.*--parent-session-id[= ]\([^ ]*\).*/\1/p')
            [ -n "$PARENT_SESSION_ID" ] && return 0
        fi
    done
    return 1
}

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

# Team agents aren't child processes, but they have --parent-session-id in their CLI args
if ! $IS_SUBAGENT && detect_parent_session_id; then
    IS_SUBAGENT=true
    IS_TEAM_AGENT=true
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

# --- Monitor process-tree helpers ---

# Return the PID of the first `claude` ancestor of this script.
get_claude_ancestor_pid() {
    local pid=$$
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] || [ "$pid" = "0" ] && break
        [ "$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)" = "claude" ] \
            && echo "$pid" && return 0
    done
    return 1
}

# Emit all descendant PIDs of $1 (recursive, breadth-first).
_descendant_pids() {
    local pid="$1"
    local children
    children=$(pgrep -P "$pid" 2>/dev/null) || return
    for child in $children; do
        echo "$child"
        _descendant_pids "$child"
    done
}

# Return 0 if the claude ancestor has live bash/sh descendants not running monitor.sh.
# Used at Stop time as a fallback when the sidecar is absent/empty.
has_live_monitor_children() {
    local claude_pid
    claude_pid=$(get_claude_ancestor_pid) || return 1
    local pid
    for pid in $(_descendant_pids "$claude_pid" 2>/dev/null); do
        local comm
        comm=$(ps -o comm= -p "$pid" 2>/dev/null | xargs basename 2>/dev/null)
        if [ "$comm" = "bash" ] || [ "$comm" = "sh" ]; then
            ps -ww -o args= -p "$pid" 2>/dev/null | grep -q "monitor\.sh" && continue
            return 0
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

# --- Detect terminal + session ID for click-to-switch ---
# Returns "app|tty_path" — TTY is always the identity (stable across restarts).
# Ghostty UUID mapping lives in tty_map.json (see seed_tty_map).
detect_terminal() {
    local tty_id=""
    local pid=$$
    for _ in 1 2 3 4 5; do
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] || [ "$pid" = "1" ] && break
        local t
        t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$t" ] && [ "$t" != "??" ]; then
            tty_id="/dev/$t"; break
        fi
    done
    [ -n "${DEVCONTAINER:-}" ] && [ -n "$tty_id" ] && tty_id="$(hostname):$tty_id"

    if [ -n "${CMUX_SURFACE_ID:-}" ]; then echo "cmux|$tty_id"
    elif [ -n "${ITERM_SESSION_ID:-}" ]; then echo "iterm2|$tty_id"
    elif [ -n "${GHOSTTY_RESOURCES_DIR:-}" ] || [ -n "${GHOSTTY_TERMINAL_UUID:-}" ]; then echo "ghostty|$tty_id"
    elif [ "${__CFBundleIdentifier:-}" = "com.t3tools.t3code" ] \
         || { [ "${CLAUDE_CODE_ENTRYPOINT:-}" = "sdk-ts" ] && [ -n "${ELECTRON_RUN_AS_NODE:-}" ]; }; then
        # T3 Code (Alpha) host — synthetic per-session id to prevent Aggregation collapse.
        # Walk ancestors to find the claude CLI PID (the hook may run in a nested shell).
        local cpid=$$ claude_pid=""
        for _ in 1 2 3 4 5; do
            cpid=$(ps -o ppid= -p "$cpid" 2>/dev/null | tr -d ' ')
            [ -z "$cpid" ] || [ "$cpid" = "1" ] && break
            if [ "$(ps -o comm= -p "$cpid" 2>/dev/null | tr -d ' ')" = "claude" ]; then
                claude_pid="$cpid"; break
            fi
        done
        echo "t3code|t3-pid-${claude_pid:-$$}"
    elif [ -n "$tty_id" ]; then echo "terminal|$tty_id"
    else echo "|"
    fi
}

# --- Cached live Ghostty UUID helper (one osascript call per hook invocation) ---
_LIVE_GHOSTTY_UUIDS=""
_LIVE_GHOSTTY_UUIDS_FETCHED=false

get_live_ghostty_uuids() {
    if $_LIVE_GHOSTTY_UUIDS_FETCHED; then
        echo "$_LIVE_GHOSTTY_UUIDS"
        return
    fi
    _LIVE_GHOSTTY_UUIDS_FETCHED=true
    _LIVE_GHOSTTY_UUIDS=$(osascript -e '
        tell application "Ghostty"
            set output to ""
            repeat with w in every window
                repeat with t in every tab of w
                    set term to focused terminal of t
                    set output to output & id of term & linefeed
                end repeat
            end repeat
            return output
        end tell' 2>/dev/null | tr -d '\r')
    echo "$_LIVE_GHOSTTY_UUIDS"
}

# --- Seed tty_map.json + tmux_map.json: TTY/tmux → Ghostty UUID mapping ---
# Called at SessionStart. Priority: env var → tmux_map → staleness-checked tty_map → focused terminal.
seed_tty_map() {
    [ "$TERM_APP" = "ghostty" ] || [ "$TERM_APP" = "cmux" ] || return 0
    [ -n "$TERM_SID" ] || return 0
    local map_file="$MONITOR_DIR/tty_map.json"
    local tmux_map_file="$MONITOR_DIR/tmux_map.json"
    local uuid=""

    # Detect tmux session name
    local tmux_session=""
    if [ -n "${TMUX:-}" ]; then
        tmux_session=$(tmux display-message -p '#S' 2>/dev/null)
    fi

    # CMUX: use env vars directly (CMUX_SURFACE_ID is the session identifier)
    if [ -n "${CMUX_SURFACE_ID:-}" ]; then
        CMUX_FRESH_SURFACE="$CMUX_LIVE_SURFACE"
        CMUX_FRESH_WORKSPACE="${CMUX_WORKSPACE_ID:-}"
        CMUX_FRESH_CHECKPOINT="${CMUX_CHECKPOINT:-}"
        return 0
    fi

    # 1. GHOSTTY_TERMINAL_UUID env var (set by shell config — always correct)
    if [ -n "${GHOSTTY_TERMINAL_UUID:-}" ]; then
        uuid="$GHOSTTY_TERMINAL_UUID"
    fi

    # 2. Existing tmux_map.json entry for this tmux session (verified live)
    if [ -z "$uuid" ] && [ -n "$tmux_session" ] && [ -f "$tmux_map_file" ]; then
        local tmux_uuid
        tmux_uuid=$(jq -r --arg ts "$tmux_session" '.[$ts] // empty' "$tmux_map_file" 2>/dev/null)
        if [ -n "$tmux_uuid" ]; then
            if get_live_ghostty_uuids | grep -qF "$tmux_uuid"; then
                uuid="$tmux_uuid"
            fi
        fi
    fi

    # 3. Staleness-checked existing TTY mapping from tty_map.json
    if [ -z "$uuid" ] && [ -f "$map_file" ]; then
        local existing_uuid
        existing_uuid=$(jq -r --arg tty "$TERM_SID" '.[$tty] // empty' "$map_file" 2>/dev/null)
        if [ -n "$existing_uuid" ]; then
            if get_live_ghostty_uuids | grep -qF "$existing_uuid"; then
                uuid="$existing_uuid"
            fi
        fi
    fi

    # 4. Focused terminal via osascript (reliable at SessionStart)
    if [ -z "$uuid" ]; then
        uuid=$(osascript -e 'tell application "Ghostty" to return id of focused terminal of selected tab of front window' 2>/dev/null)
    fi

    [ -n "$uuid" ] || return 0

    # Export resolved UUID for session JSON
    GHOSTTY_RESOLVED_UUID="$uuid"

    # Write tty_map.json (TTY → UUID)
    local existing="{}"
    [ -f "$map_file" ] && existing=$(cat "$map_file" 2>/dev/null || echo "{}")
    echo "$existing" | jq --arg tty "$TERM_SID" --arg uuid "$uuid" \
        '.[$tty] = $uuid' > "${map_file}.tmp" && mv "${map_file}.tmp" "$map_file"

    # Write tmux_map.json (tmux_session → UUID) if in tmux
    if [ -n "$tmux_session" ]; then
        local tmux_existing="{}"
        [ -f "$tmux_map_file" ] && tmux_existing=$(cat "$tmux_map_file" 2>/dev/null || echo "{}")
        echo "$tmux_existing" | jq --arg ts "$tmux_session" --arg uuid "$uuid" \
            '.[$ts] = $uuid' > "${tmux_map_file}.tmp" && mv "${tmux_map_file}.tmp" "$tmux_map_file"
    fi
}

# --- Detect terminal once for all events ---
TERM_INFO=$(detect_terminal)
TERM_APP=$(echo "$TERM_INFO" | cut -d'|' -f1)
TERM_SID=$(echo "$TERM_INFO" | cut -d'|' -f2)

# CMUX: re-derive live surface UUID from $TMUX socket path on every invocation.
# Each CMUX surface IS a separate tmux server; the socket name encodes the UUID.
# $CMUX_SURFACE_ID is frozen at launch; $TMUX is also frozen but the socket's
# liveness tells us if the surface is still valid. If the socket is dead (CMUX
# restarted and created a new surface), scan cmux-* sockets by our TTY to find
# the current surface UUID.
CMUX_LIVE_SURFACE=""
_cmux_found_sock=""
if [ "$TERM_APP" = "cmux" ] && [ -n "${TMUX:-}" ]; then
    _tmux_sock=$(echo "$TMUX" | cut -d',' -f1)
    _uuid=$(basename "$_tmux_sock" | sed 's/^cmux-//')
    if echo "$_uuid" | grep -qE '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'; then
        if [ -S "$_tmux_sock" ]; then
            # Socket alive — this is the current surface
            CMUX_LIVE_SURFACE="$_uuid"
        else
            # Socket dead: CMUX restarted and the surface was reassigned.
            # Find current surface by scanning cmux-* sockets for our TTY.
            _uid=$(id -u)
            for _s in /private/tmp/tmux-${_uid}/cmux-*; do
                [ -S "$_s" ] || continue
                if tmux -S "$_s" list-panes -a -F "#{pane_tty}" 2>/dev/null | grep -qF "$TERM_SID"; then
                    CMUX_LIVE_SURFACE=$(basename "$_s" | sed 's/^cmux-//')
                    _cmux_found_sock="$_s"
                    break
                fi
            done
        fi
    fi
fi
# Fallback: use frozen env var if detection failed (non-CMUX sessions, or no TMUX)
[ -z "$CMUX_LIVE_SURFACE" ] && CMUX_LIVE_SURFACE="${CMUX_SURFACE_ID:-}"
# Stable checkpoint: tmux session name survives CMUX restarts (surface/workspace UUIDs do not)
CMUX_CHECKPOINT=""
if [ "$TERM_APP" = "cmux" ]; then
    if [ -n "$_cmux_found_sock" ]; then
        CMUX_CHECKPOINT=$(tmux -S "$_cmux_found_sock" display-message -p '#{session_name}' 2>/dev/null || true)
    elif [ -n "${TMUX:-}" ]; then
        CMUX_CHECKPOINT=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
    fi
fi

# --- Sub-agent event handling ---
if [ "$IS_SUBAGENT" = "true" ]; then
    if [ "${IS_TEAM_AGENT:-false}" = "true" ]; then
        # Team agent: use own session file with parent_session_id set
        case "$EVENT" in
            SessionStart)
                GHOSTTY_RESOLVED_UUID=""
                seed_tty_map
                jq -n \
                    --arg sid "$SESSION_ID" \
                    --arg status "working" \
                    --arg project "$PROJECT" \
                    --arg cwd "${CWD:-}" \
                    --arg terminal "$TERM_APP" \
                    --arg term_sid "$TERM_SID" \
                    --arg parent "$PARENT_SESSION_ID" \
                    --arg ghostty_id "$GHOSTTY_RESOLVED_UUID" \
                    --arg cmux_sid "${CMUX_FRESH_SURFACE:-}" \
                    --arg cmux_wid "${CMUX_FRESH_WORKSPACE:-}" \
                    --arg cmux_ckpt "${CMUX_FRESH_CHECKPOINT:-}" \
                    --arg now "$NOW" \
                    '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0, parent_session_id: $parent} | if $ghostty_id != "" then .ghostty_terminal_id = $ghostty_id else . end | if $cmux_sid != "" then .cmux_surface_id = $cmux_sid else . end | if $cmux_wid != "" then .cmux_workspace_id = $cmux_wid else . end | if $cmux_ckpt != "" then .cmux_checkpoint = $cmux_ckpt else . end' \
                    > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
                ;;
            Notification)
                NOTIF_TYPE=$(echo "$INPUT" | jq -r '.notification_type // "unknown"')
                if [ -f "$SESSION_FILE" ]; then
                    if [ "$NOTIF_TYPE" = "idle_prompt" ]; then
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            '.status = "idle" | .updated_at = $updated'
                    elif [ "$NOTIF_TYPE" = "permission_prompt" ]; then
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            '.status = "attention" | .updated_at = $updated'
                    fi
                fi
                ;;
            UserPromptSubmit)
                PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' | head -c 200)
                if [ -f "$SESSION_FILE" ]; then
                    update_json_file "$SESSION_FILE" --arg updated "$NOW" --arg prompt "$PROMPT" \
                        'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end | if $prompt != "" then .last_prompt = $prompt else . end'
                fi
                ;;
            PreToolUse)
                TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
                if [ -f "$SESSION_FILE" ]; then
                    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            '.status = "attention" | .updated_at = $updated'
                    else
                        update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                            'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
                    fi
                fi
                ;;
            PostToolUse|PostToolUseFailure)
                if [ -f "$SESSION_FILE" ]; then
                    update_json_file "$SESSION_FILE" --arg updated "$NOW" \
                        'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
                fi
                ;;
            Stop|SessionEnd)
                rm -f "$SESSION_FILE" "$SESSIONS_DIR/${SESSION_ID}.context" "$SESSIONS_DIR/${SESSION_ID}.model"
                ;;
            *)
                # All other team agent events: ignore
                ;;
        esac
    else
        # Regular sub-agent: transcript-path based
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
            PreToolUse)
                TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
                if ensure_subagent_file; then
                    if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                        update_json_file "$SUBAGENT_SESSION_FILE" --arg updated "$NOW" \
                            '.status = "attention" | .updated_at = $updated'
                    else
                        update_json_file "$SUBAGENT_SESSION_FILE" --arg updated "$NOW" \
                            'if .status != "working" then .status = "working" | .updated_at = $updated else .updated_at = $updated end'
                    fi
                fi
                ;;
            PostToolUse|PostToolUseFailure)
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
    fi
    exit 0
fi

# Helper: create session file if missing or corrupt (hooks bootstrap it on first event after monitor restart)
ensure_session_file() {
    # Check file exists AND has valid JSON (empty/corrupt files need recreation)
    if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ] && jq -e . "$SESSION_FILE" >/dev/null 2>&1; then
        return 0
    fi
    local skip_val="false"
    if detect_skip_permissions || [ -n "${DEVCONTAINER:-}" ]; then skip_val="true"; fi
    jq -n \
        --arg sid "$SESSION_ID" --arg status "idle" \
        --arg project "$PROJECT" --arg cwd "${CWD:-}" \
        --arg terminal "$TERM_APP" --arg term_sid "$TERM_SID" \
        --arg csid "${CMUX_LIVE_SURFACE:-}" \
        --arg cwid "${CMUX_WORKSPACE_ID:-}" \
        --arg ckpt "${CMUX_CHECKPOINT:-}" \
        --argjson skip "$skip_val" \
        --arg now "$NOW" \
        '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0} | if $csid != "" then .cmux_surface_id = $csid else . end | if $cwid != "" then .cmux_workspace_id = $cwid else . end | if $ckpt != "" then .cmux_checkpoint = $ckpt else . end | if $skip then .skip_permissions = true else . end' \
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
        --arg csid "${CMUX_LIVE_SURFACE:-}" \
        --arg cwid "${CMUX_WORKSPACE_ID:-}" \
        --arg ckpt "${CMUX_CHECKPOINT:-}" \
        '.updated_at = $updated | if .terminal == "" then .terminal = $terminal | .terminal_session_id = $term_sid else . end | if $csid != "" then .cmux_surface_id = $csid else . end | if $cwid != "" then .cmux_workspace_id = $cwid else . end | if $ckpt != "" then .cmux_checkpoint = $ckpt else . end'
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
        # If terminal detection failed, inherit from a recently-ended session in same CWD
        if [ -z "$TERM_SID" ] && [ -n "$CWD" ]; then
            for f in "$SESSIONS_DIR"/*.json; do
                [ -f "$f" ] || continue
                local_status=$(jq -r '.status // ""' "$f" 2>/dev/null)
                [ "$local_status" = "ended" ] || continue
                local_cwd=$(jq -r '.cwd // ""' "$f" 2>/dev/null)
                [ "$local_cwd" = "$CWD" ] || continue
                local_term=$(jq -r '.terminal // ""' "$f" 2>/dev/null)
                local_tid=$(jq -r '.terminal_session_id // ""' "$f" 2>/dev/null)
                if [ -n "$local_tid" ]; then
                    TERM_APP="${local_term}"
                    TERM_SID="${local_tid}"
                    break
                fi
            done
        fi
        cleanup_same_terminal
        GHOSTTY_RESOLVED_UUID=""
        seed_tty_map
        # Detect --dangerously-skip-permissions once at session start.
        # Fallback: devcontainer sessions always run with skip-permissions (injected by claude.fish).
        if detect_skip_permissions || [ -n "${DEVCONTAINER:-}" ]; then
            SKIP_PERMS=true
        else
            SKIP_PERMS=false
        fi
        if [ -f "$SESSION_FILE" ] && [ -s "$SESSION_FILE" ]; then
            # Session file exists — backfill terminal and reboot if dead
            backfill_terminal
            CURRENT_STATUS=$(jq -r '.status // ""' "$SESSION_FILE" 2>/dev/null)
            if [ "$CURRENT_STATUS" = "dead" ] || [ "$CURRENT_STATUS" = "ended" ]; then
                update_json_file "$SESSION_FILE" \
                    --arg status "idle" \
                    --arg updated "$NOW" \
                    '.status = $status | .updated_at = $updated'
            fi
            # Persist ghostty_terminal_id if resolved
            if [ -n "$GHOSTTY_RESOLVED_UUID" ]; then
                update_json_file "$SESSION_FILE" --arg gid "$GHOSTTY_RESOLVED_UUID" \
                    '.ghostty_terminal_id = $gid'
            fi
            # Persist CMUX surface/workspace/checkpoint IDs if resolved
            if [ -n "${CMUX_FRESH_SURFACE:-}" ]; then
                update_json_file "$SESSION_FILE" \
                    --arg csid "${CMUX_FRESH_SURFACE}" \
                    --arg cwid "${CMUX_FRESH_WORKSPACE:-}" \
                    --arg ckpt "${CMUX_FRESH_CHECKPOINT:-}" \
                    '.cmux_surface_id = $csid | if $cwid != "" then .cmux_workspace_id = $cwid else . end | if $ckpt != "" then .cmux_checkpoint = $ckpt else . end'
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
                    --arg ghostty_id "$GHOSTTY_RESOLVED_UUID" \
                    --arg cmux_sid "${CMUX_FRESH_SURFACE:-}" \
                    --arg cmux_wid "${CMUX_FRESH_WORKSPACE:-}" \
                    --arg cmux_ckpt "${CMUX_FRESH_CHECKPOINT:-}" \
                    --arg now "$NOW" \
                    '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0, skip_permissions: true} | if $ghostty_id != "" then .ghostty_terminal_id = $ghostty_id else . end | if $cmux_sid != "" then .cmux_surface_id = $cmux_sid else . end | if $cmux_wid != "" then .cmux_workspace_id = $cmux_wid else . end | if $cmux_ckpt != "" then .cmux_checkpoint = $cmux_ckpt else . end' \
                    > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
            else
                jq -n \
                    --arg sid "$SESSION_ID" \
                    --arg status "starting" \
                    --arg project "$PROJECT" \
                    --arg cwd "${CWD:-}" \
                    --arg terminal "$TERM_APP" \
                    --arg term_sid "$TERM_SID" \
                    --arg ghostty_id "$GHOSTTY_RESOLVED_UUID" \
                    --arg cmux_sid "${CMUX_FRESH_SURFACE:-}" \
                    --arg cmux_wid "${CMUX_FRESH_WORKSPACE:-}" \
                    --arg cmux_ckpt "${CMUX_FRESH_CHECKPOINT:-}" \
                    --arg now "$NOW" \
                    '{session_id: $sid, status: $status, project: $project, cwd: $cwd, terminal: $terminal, terminal_session_id: $term_sid, started_at: $now, updated_at: $now, last_prompt: "", agent_count: 0} | if $ghostty_id != "" then .ghostty_terminal_id = $ghostty_id else . end | if $cmux_sid != "" then .cmux_surface_id = $cmux_sid else . end | if $cmux_wid != "" then .cmux_workspace_id = $cmux_wid else . end | if $cmux_ckpt != "" then .cmux_checkpoint = $cmux_ckpt else . end' \
                    > "${SESSION_FILE}.tmp" && mv "${SESSION_FILE}.tmp" "$SESSION_FILE"
            fi
        fi
        ;;

    Stop)
        ensure_session_file
        if [ -f "$SESSION_FILE" ]; then
            if [ -f "$MONITORS_FILE" ] && [ -s "$MONITORS_FILE" ]; then
                # Sidecar is non-empty — a Monitor is still tracked as alive; leave status as working.
                update_json_file "$SESSION_FILE" \
                    --arg updated "$NOW" \
                    'if .status == "dead" then . else .updated_at = $updated end'
            elif has_live_monitor_children; then
                # Process-tree fallback: sidecar missed it but bash children are still running.
                rm -f "$MONITORS_FILE"
                update_json_file "$SESSION_FILE" \
                    --arg updated "$NOW" \
                    'if .status == "dead" then . else .updated_at = $updated end'
            else
                rm -f "$MONITORS_FILE"
                update_json_file "$SESSION_FILE" \
                    --arg status "idle" \
                    --arg updated "$NOW" \
                    'if .status == "dead" then . else .status = $status | .updated_at = $updated end'
            fi
        fi
        # Skip notification for team agent sessions.
        # detect_parent_session_id is re-checked here as a fallback in case the process
        # tree wasn't fully established when it ran at script start.
        if ! detect_parent_session_id; then
            command -v cmux >/dev/null 2>&1 && cmux notify --title "Claude Code" --body "Session complete: $PROJECT_NAME"
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
        command -v cmux >/dev/null 2>&1 && cmux notify --title "Claude Code" --body "Needs attention: $PROJECT_NAME"
        ;;

    SessionEnd)
        # Session ended — soft-delete: set status to "ended" (preserves terminal_session_id
        # so SessionStart can reuse it instead of re-detecting the wrong terminal).
        # Still delete sidecar files.
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg status "ended" \
                --arg updated "$NOW" \
                '.status = $status | .updated_at = $updated'
        fi
        rm -f "$SESSIONS_DIR/${SESSION_ID}.context" "$SESSIONS_DIR/${SESSION_ID}.model" "$MONITORS_FILE"
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

    UserPromptSubmit)
        # User submitted prompt — set working and persist last_prompt
        ensure_session_file
        backfill_terminal
        PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' | head -c 200)
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg updated "$NOW" \
                --arg prompt "$PROMPT" \
                'if .status == "dead" then . else .status = "working" | .updated_at = $updated | if $prompt != "" then .last_prompt = $prompt else . end end'
        fi
        ;;

    PostToolUse|PostToolUseFailure)
        # Tool completed — clear attention and set working.
        # PostToolUse/PostToolUseFailure means user answered any permission prompt
        # or finished an AskUserQuestion (T3's prompt mechanism).
        ensure_session_file
        backfill_terminal
        if [ -f "$SESSION_FILE" ]; then
            update_json_file "$SESSION_FILE" \
                --arg updated "$NOW" \
                'if .status == "dead" then . else .status = "working" | .updated_at = $updated end'
        fi
        # Track Monitor tasks in sidecar so Stop knows not to set idle.
        TOOL_NAME_PTU=$(echo "$INPUT" | jq -r '.tool_name // ""')
        if [ "$TOOL_NAME_PTU" = "Monitor" ]; then
            # tool_response may be an object with task_id, or a text string containing "task <id>"
            MONITOR_TASK_ID=$(echo "$INPUT" | jq -r '
                .tool_response |
                if type == "object" then .task_id // ""
                elif type == "string" then .
                else "" end
            ' 2>/dev/null | grep -oE '\btask [a-z0-9]+\b' | awk '{print $2}')
            # Also try direct object field if grep found nothing
            if [ -z "$MONITOR_TASK_ID" ]; then
                MONITOR_TASK_ID=$(echo "$INPUT" | jq -r '.tool_response.task_id // empty' 2>/dev/null)
            fi
            if [ -n "$MONITOR_TASK_ID" ]; then
                echo "$MONITOR_TASK_ID" >> "$MONITORS_FILE"
            fi
        fi
        ;;

    PreToolUse)
        # T3 (sdk-ts entrypoint) does not fire Notification; it prompts the user via
        # the AskUserQuestion tool. PreToolUse fires before the user answers, so flip
        # to attention. PostToolUse (above) clears it back to working.
        TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
        if [ "$TOOL_NAME" = "TaskStop" ]; then
            # Remove the stopped task from the monitors sidecar (if present).
            STOPPING_TASK_ID=$(echo "$INPUT" | jq -r '.tool_input.task_id // empty' 2>/dev/null)
            if [ -n "$STOPPING_TASK_ID" ] && [ -f "$MONITORS_FILE" ]; then
                sed -i '' "/^${STOPPING_TASK_ID}$/d" "$MONITORS_FILE"
            fi
            backfill_terminal
            set_working
        elif [ "$TOOL_NAME" = "AskUserQuestion" ] || [ "$TOOL_NAME" = "ExitPlanMode" ]; then
            ensure_session_file
            backfill_terminal
            if [ -f "$SESSION_FILE" ]; then
                update_json_file "$SESSION_FILE" \
                    --arg updated "$NOW" \
                    'if .status == "dead" then . else .status = "attention" | .updated_at = $updated end'
            fi
            command -v cmux >/dev/null 2>&1 && cmux notify --title "Claude Code" --body "Needs attention: $PROJECT_NAME"
        else
            # Other PreToolUse: backfill terminal and set working (fires after user
            # approves a permission prompt, so this also clears attention).
            backfill_terminal
            set_working
        fi
        ;;

    *)
        # All other events: backfill terminal and set working.
        backfill_terminal
        set_working
        ;;
esac

# Persist permission_mode to session file whenever the hook supplies it.
if [ -n "$PERMISSION_MODE" ] && [ -f "$SESSION_FILE" ]; then
    CURRENT_PM=$(jq -r '.permission_mode // ""' "$SESSION_FILE" 2>/dev/null)
    if [ "$CURRENT_PM" != "$PERMISSION_MODE" ]; then
        update_json_file "$SESSION_FILE" --arg pm "$PERMISSION_MODE" '.permission_mode = $pm'
    fi
fi

exit 0
