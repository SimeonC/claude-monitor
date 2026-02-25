# Architecture

Technical deep-dive into how Claude Monitor works.

## Overview

Claude Monitor is two components: a **bash hook script** that captures session lifecycle events, and a **SwiftUI app** that displays them as a floating panel.

```
┌─────────────────────┐     JSON files      ┌────────────────────┐
│  monitor.sh (hook)  │ ──────────────────── │  claude_monitor    │
│                     │   ~/.claude/monitor  │  (SwiftUI app)     │
│  - Runs on every    │   /sessions/{id}.json│                    │
│    Claude Code event│                      │  - FSEvents watcher│
│  - Writes session   │                      │  - Floating panel  │
│    JSON             │                      │  - Click to switch │
└─────────────────────┘                      └────────────────────┘
```

The two components communicate through the filesystem — no sockets, no IPC, no daemon. The hook writes JSON files; the app detects changes via FSEvents.

## Hook Script (`monitor.sh`)

Handles all 7 Claude Code lifecycle events:

```bash
monitor.sh <event>   # receives hook JSON on stdin
```

### Event Flow

1. **Sub-agent detection** — walks the process tree looking for two `claude` ancestors; if found, this is a sub-agent hook and exits early
2. **Parse input** — reads JSON from stdin, extracts `session_id` and `cwd`
3. **Detect terminal** — identifies Ghostty (`GHOSTTY_RESOURCES_DIR`), iTerm2 (`ITERM_SESSION_ID`), or Terminal.app (TTY from process tree)
4. **Write session file** — creates or updates `~/.claude/monitor/sessions/{id}.json`

### Event → Status Mapping

| Event | Action |
|-------|--------|
| `SessionStart` | Create session file with `starting` status; reboot `dead`/`shutting_down` → `starting` for `--continue` |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | Set `working` (unless `dead`) |
| `Stop` | Set `idle` (unless `dead`) |
| `Notification` (idle_prompt) | Set `idle` (unless `dead`) |
| `Notification` (permission_prompt) | Set `attention` (unless `dead`) |
| `SessionEnd` | Set `shutting_down` |

Dead sessions are never revived by non-start events — guards in every handler check for `status == "dead"` and skip the update.

### Terminal Detection

Hook subprocesses can't use the `tty` command (stdin is piped). Instead, the script walks up the process tree via `ps -o ppid=` to find the first ancestor with a real TTY device:

```
Hook process (stdin = pipe, no tty)
  └── parent shell (bash/zsh/fish)
       └── Claude Code process
            └── shell on TTY ← found: /dev/ttys018
```

For iTerm2, the `ITERM_SESSION_ID` environment variable is used directly. For Ghostty, `GHOSTTY_RESOURCES_DIR` identifies the terminal, and the TTY path is stored for liveness checks.

### Non-Destructive Session Management

Session `.json` files are **never deleted**. All cleanup operations set `status = "dead"` instead of removing the file. This prevents `jq` errors when concurrent hooks try to read a file that was just deleted by another hook.

- `cleanup_same_terminal()` — marks stale sessions for the same terminal tab as `dead`
- `SessionStart` on a `dead` session — reboots it to `starting` (supports `--continue`)

### Atomic Writes

All file operations use the tmp-and-rename pattern to prevent the SwiftUI app from reading partial JSON:

```bash
jq '...' > "${file}.tmp" && mv "${file}.tmp" "$file"
```

## SwiftUI App (`claude_monitor.swift`)

Single-file SwiftUI app, compiled to a standalone binary.

### Key Classes

| Class | Role |
|-------|------|
| `SessionReader` | Watches `sessions/` via FSEvents, decodes JSON, aggregates by project, scans JSONL files for auto-discovery |
| `TeamReader` | Watches `~/.claude/teams/` and `~/.claude/tasks/` for team agent activity |
| `DirectoryWatcher` | Generic FSEvents wrapper for low-latency file change detection |
| `ConfigManager` | Reads/writes `config.json`, manages voice selection |
| `VoiceFetcher` | Fetches ElevenLabs voice library via API |
| `FloatingPanel` | `NSPanel` subclass — borderless, always-on-top, non-activating |
| `ClickHostingView` | `NSHostingView` with `acceptsFirstMouse` for click-through |
| `ThinScroller` | Custom `NSScroller` subclass for the themed scrollbar |

### Panel Behavior

The panel uses `NSPanel` with `.nonactivatingPanel` style, which means:
- It floats above all windows without stealing keyboard focus
- It follows you across all Spaces (`canJoinAllSpaces`)
- It doesn't appear in the Dock or Cmd+Tab switcher (`.accessory` activation policy)
- Buttons work via AppKit-level interception, even with `isMovableByWindowBackground`

**Known tradeoff**: `nonactivatingPanel` popovers can't receive keyboard input. The voice ID selector uses clipboard paste as a workaround.

### Auto-Resize

The panel grows downward from its top edge. A KVO observer on `fittingSize` adjusts the frame whenever content changes:

```
Top edge (anchored) ──────────────
│  Header bar                    │
│  Session 1                     │
│  Session 2                     │
│  Session 3 (new — panel grows) │
Bottom edge (moves down) ────────
```

### Session Lifecycle Management

**FSEvents watchers**: The app uses FSEvents (not polling) to detect changes to session files, JSONL files, and team config files. Changes trigger an immediate re-read.

**JSONL scanning**: The primary session discovery mechanism. Scans `~/.claude/projects/` for recently-modified `.jsonl` files, extracts CWD and last prompt, and creates/updates session files. This catches sessions that hooks missed (e.g., sessions started before hooks were installed).

**Liveness check**: A periodic timer (every 30s) checks whether each session's `claude` process is still running:
1. **Primary**: Check JSONL file mtime — if older than 12 hours, mark dead
2. **Fallback (Terminal/Ghostty)**: Check if `claude` is running on the session's TTY
3. **Fallback (iTerm2)**: AppleScript queries iTerm2 for the session's TTY, then checks for claude
4. **Fallback (no info)**: Mark stale sessions without terminal info or JSONL as dead

Dead sessions are marked `status = "dead"` (file stays on disk). Team leads with active agents are protected from pruning.

**Boot cleanup**: On startup, sessions with `updated_at` before the app's boot time are marked dead (leftover from a previous crash).

### Terminal Tab Switching

Three strategies based on terminal type:

- **Ghostty** — Accessibility API reads each window's `AXDocument` (file URL of CWD) and title. Hybrid scoring: AXDocument match scores 30 (best for direct Claude windows), tmux title match scores 25, other title match scores 20. Case-insensitive path comparison handles macOS filesystem casing differences. Multi-tab windows score each tab individually.
- **Terminal.app** — AppleScript iterates all windows/tabs, matches `tty of t` against the stored TTY path
- **iTerm2** — AppleScript matches `unique id of s` against the stored `ITERM_SESSION_ID`

### Session Kill

When killing a session:

1. For Terminal.app/Ghostty: `pkill -TERM -t <tty> -f claude` sends SIGTERM to claude processes on that TTY
2. For iTerm2: AppleScript gets the TTY from the iTerm2 session, then uses the same `pkill` approach
3. Session file is marked `status = "dead"` after 3 seconds (file stays on disk)

## Session JSON Schema

```json
{
  "session_id": "uuid",
  "status": "starting | working | idle | attention | shutting_down | dead",
  "project": "directory-name",
  "cwd": "/absolute/path",
  "terminal": "ghostty | iterm2 | terminal",
  "terminal_session_id": "/dev/ttys018 | w0t0p0:GUID",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "last_prompt": "first 200 chars of last user prompt",
  "agent_count": 0
}
```

The decoder uses `decodeIfPresent` with defaults for all fields except `session_id`, making it resilient to schema changes or partial writes. Corrupt files are skipped (never deleted).
