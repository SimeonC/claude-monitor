<div align="center">

# Claude Monitor

**A floating macOS dashboard for all your Claude Code sessions.**

See what's working, what's idle, and what needs attention — at a glance.

<br>

<img src="assets/sessions.png" width="380" alt="Claude Monitor — session list with live status" />

<br>
<br>

</div>

---

If you run multiple Claude Code sessions at once, you know the pain: switching tabs to check which one finished, which one is waiting for permission, which one is still thinking. Claude Monitor fixes that.

A tiny always-on-top panel you can drag anywhere on your screen. It shows every active Claude Code session with its status, project name, and last prompt. Click a row to jump straight to that terminal tab.

<div align="center">
<img src="assets/shortcuts.png" width="420" alt="Jump shortcuts popover" />
<br>
<sub>Configurable global keyboard shortcuts to cycle between sessions</sub>
</div>

## Features

- **Live status** for every session — working, idle, or needs attention — with color-coded dots
- **Click to jump** to any session's terminal tab (Ghostty, iTerm2, Terminal.app)
- **Global keyboard shortcuts** to cycle between sessions needing attention
- **Team agent badges** when sessions spawn sub-agents
- **Project name, elapsed time, and last prompt** preview per session
- **Right-click context menu** to delete sessions or relink Ghostty tabs
- **Always-on-top** dark glass panel, visible on all Spaces, no dock icon
- **Auto-discovery** via JSONL scanning — sessions appear without manual refresh

## Install

### Requirements

- **macOS 14+** (Sonoma or later)
- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** CLI
- **Xcode Command Line Tools** — `xcode-select --install`
- **jq** — `brew install jq`
- **Ghostty 1.3.0+, iTerm2, or Terminal.app**

### Setup

```bash
git clone https://github.com/SimeonC/claude-monitor.git
cd claude-monitor
./install.sh
```

The install script is idempotent — it creates directories, merges hooks into `~/.claude/settings.json`, builds the binary, installs a LaunchAgent, and starts the monitor. Run the same command to update.

The floating panel appears in the top-right corner. Drag to reposition — it remembers where you put it.

#### Fish shell

If you use [fish](https://fishshell.com/), save the following as `~/.config/fish/functions/claude.fish`. It wraps the `claude` command with tmux session management, propagates the Ghostty terminal UUID for click-to-switch, and adds devcontainer support.

```fish
function claude --wraps=claude --description 'Claude Code with tmux session management'
    # Pass-through for non-interactive subcommands
    if test (count $argv) -ge 1
        switch "$argv[1]"
            case update mcp config --help -h --version -v
                command claude $argv
                return
        end
    end

    set -l claude_args $argv
    if set -q DEVCONTAINER
        set claude_args --dangerously-skip-permissions $argv
    end

    set -l short_cwd (string replace "$HOME" "~" "$PWD")

    if not set -q TMUX
        # Not in tmux — create a detached session, send claude into it, attach
        set -l sess_name "claude-$fish_pid"
        tmux new-session -d -s $sess_name -x (tput cols) -y (tput lines)
        tmux set-option -wt $sess_name automatic-rename off
        tmux rename-window -t $sess_name "$short_cwd"
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        # Propagate Ghostty terminal UUID into tmux session (conf.d captures it
        # at tab open when the tab is guaranteed focused; tmux server env may carry
        # a different tab's UUID, so we explicitly forward the correct one)
        if set -q GHOSTTY_TERMINAL_UUID
            tmux send-keys -t $sess_name "set -gx GHOSTTY_TERMINAL_UUID '$GHOSTTY_TERMINAL_UUID'; command claude $claude_args" Enter
        else
            tmux send-keys -t $sess_name "command claude $claude_args" Enter
        end
        tmux attach-session -t $sess_name
    else
        # Already in tmux — rename current window and run directly
        tmux set-option -w automatic-rename off
        tmux rename-window "$short_cwd"
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        command claude $claude_args
    end
end
```

#### Devcontainers

Click-to-switch works inside devcontainers if you set the `GHOSTTY_TERMINAL_UUID` environment variable before launching Claude. Since `osascript` isn't available inside containers, the hook can't detect the Ghostty terminal UUID at runtime. Instead, capture it on the host and forward it in:

```bash
# On the host, before entering the container:
TERM_UUID=$(osascript -e 'tell application "Ghostty" to return id of focused terminal of selected tab of front window')
devcontainer exec --remote-env "GHOSTTY_TERMINAL_UUID=$TERM_UUID" -- claude
```

The monitor hook checks for this variable first and uses it directly, skipping the AppleScript call.

#### Tmux + Ghostty

If you run Claude inside tmux panes within Ghostty tabs, you need **two things** for reliable click-to-switch with multiple sessions in the same directory:

1. **A shell snippet that captures the Ghostty terminal UUID when the tab opens** — the tab is guaranteed focused at this moment, so the UUID is always correct.
2. **The `claude.fish` wrapper** (above) **propagates this UUID into tmux sessions** — without this, the tmux server inherits the UUID from whichever tab started it first, causing all sessions to map to the same tab.

**Fish** — save as `~/.config/fish/conf.d/ghostty-uuid.fish`:

```fish
if test -n "$GHOSTTY_RESOURCES_DIR"; and not set -q GHOSTTY_TERMINAL_UUID
    set -gx GHOSTTY_TERMINAL_UUID (osascript -e 'tell application "Ghostty" to return id of focused terminal of selected tab of front window' 2>/dev/null)
end
```

**Zsh** — add to `~/.zshrc`:

```zsh
if [[ -n "$GHOSTTY_RESOURCES_DIR" && -z "$GHOSTTY_TERMINAL_UUID" ]]; then
    export GHOSTTY_TERMINAL_UUID=$(osascript -e 'tell application "Ghostty" to return id of focused terminal of selected tab of front window' 2>/dev/null)
fi
```

The UUID is captured once when the Ghostty tab opens (when it's definitively focused). The "not already set" guard prevents child shells (including tmux panes) from re-capturing a different value. The `claude.fish` wrapper then forwards this UUID into the tmux session it creates, ensuring each session gets the correct tab's UUID regardless of tmux server environment.

### Uninstall

```bash
pkill claude_monitor
rm -rf ~/.claude/monitor ~/.claude/hooks/monitor.sh
launchctl bootout "gui/$(id -u)/com.claude.monitor" 2>/dev/null
rm -f ~/Library/LaunchAgents/com.claude.monitor.plist
```

Then remove the hook entries from `~/.claude/settings.json`.

## How It Works

Claude Code hooks fire on session events → `monitor.sh` writes session JSON to `~/.claude/monitor/sessions/` → the Swift app detects changes via FSEvents and updates the floating panel. Session files are never deleted — status transitions replace destructive removal to prevent race conditions in concurrent hooks.

## Credits

Originally created by [brb-dreaming](https://github.com/brb-dreaming/claude-monitor). This fork has diverged significantly with keyboard shortcuts, team agent support, session auto-discovery, and many other changes.

## License

[MIT](LICENSE)
