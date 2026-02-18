# Architecture

Technical deep-dive into how Claude Monitor works.

## Overview

Claude Monitor is two components: a **bash hook script** that captures session lifecycle events, and a **SwiftUI app** that displays them as a floating panel.

```
┌─────────────────────┐     JSON files      ┌────────────────────┐
│  monitor.sh (hook)  │ ──────────────────── │  claude_monitor    │
│                     │   ~/.claude/monitor  │  (SwiftUI app)     │
│  - Runs on every    │   /sessions/{id}.json│                    │
│    Claude Code event│                      │  - Polls every     │
│  - Writes session   │                      │    500ms           │
│    JSON             │                      │  - Floating panel  │
│  - Triggers TTS     │                      │  - Click to switch │
└─────────────────────┘                      └────────────────────┘
```

The two components communicate through the filesystem — no sockets, no IPC, no daemon. The hook writes JSON files; the app reads them.

## Hook Script (`monitor.sh`)

Handles all 5 Claude Code lifecycle events:

```bash
monitor.sh <event>   # receives hook JSON on stdin
```

### Event Flow

1. **Parse input** — reads JSON from stdin, extracts `session_id` and `cwd`
2. **Detect terminal** — walks the process tree to find the parent shell's TTY
3. **Write session file** — creates or updates `~/.claude/monitor/sessions/{id}.json`
4. **Announce** — optionally speaks status via macOS `say` or ElevenLabs API

### Terminal Detection

Hook subprocesses can't use the `tty` command (stdin is piped). Instead, the script walks up the process tree via `ps -o ppid=` to find the first ancestor with a real TTY device:

```
Hook process (stdin = pipe, no tty)
  └── parent shell (bash/zsh)
       └── Claude Code process
            └── shell on TTY ← found: /dev/ttys018
```

For iTerm2, the `ITERM_SESSION_ID` environment variable is used directly (set by iTerm2 on session creation).

### Atomic Writes

All file operations use the tmp-and-rename pattern to prevent the SwiftUI app from reading partial JSON:

```bash
jq '...' > "${file}.tmp" && mv "${file}.tmp" "$file"
```

### TTS Integration

Two providers, same interface:

- **macOS `say`** — uses `osascript` for volume control: `say "text" using "voice" speaking rate N volume V`
- **ElevenLabs** — `curl` POST to `/v1/text-to-speech/{voice_id}`, plays response with `afplay -v`

Both run in the background (`&` + `disown`) to avoid blocking the hook.

## SwiftUI App (`claude_monitor.swift`)

Single-file SwiftUI app, compiled to a standalone binary.

### Key Classes

| Class | Role |
|-------|------|
| `SessionReader` | Polls `sessions/` directory every 500ms, decodes JSON, sorts by priority |
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

**Liveness check**: Every 5 seconds, the app checks if each session's TTY still has processes running. If the terminal tab was closed (no processes on TTY), the session file is removed automatically.

**Discovery**: The refresh button in settings scans for running `claude` processes, finds their TTYs and working directories, and creates session files for any that aren't tracked.

### Terminal Tab Switching

Two strategies based on terminal type:

- **Terminal.app** — AppleScript iterates all windows/tabs, matches `tty of t` against the stored TTY path
- **iTerm2** — AppleScript matches `unique id of s` against the stored `ITERM_SESSION_ID`

### Session Kill

When killing a session:

1. For Terminal.app: `pkill -TERM -t <tty> -f claude` sends SIGTERM to claude processes on that TTY
2. For iTerm2: AppleScript gets the TTY from the iTerm2 session, then uses the same `pkill` approach
3. Session file is cleaned up after 3 seconds

## Session JSON Schema

```json
{
  "session_id": "uuid",
  "status": "starting | working | done | attention",
  "project": "directory-name",
  "cwd": "/absolute/path",
  "terminal": "terminal | iterm2",
  "terminal_session_id": "/dev/ttys018 | w0t0p0:GUID",
  "started_at": "ISO8601",
  "updated_at": "ISO8601",
  "last_prompt": "first 200 chars of last user prompt"
}
```

The decoder uses `decodeIfPresent` with defaults for all fields except `session_id`, making it resilient to schema changes or partial writes.
