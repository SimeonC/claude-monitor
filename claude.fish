function claude --wraps=claude --description 'Claude Code with tmux session management'
    # Read + increment counter (persists in ~/.claude so it works across host + devcontainers)
    set -l counter_file "$HOME/.claude/monitor_counter"
    set -l next 1
    if test -f "$counter_file"
        set next (math (cat "$counter_file") + 1)
    else
        # Migrate from old TMPDIR-based counter
        set -l old_counter "$TMPDIR/claude_monitor_counter"
        if test -f "$old_counter"
            set next (math (cat "$old_counter") + 1)
        end
    end
    echo $next >"$counter_file"

    # Pass-through without tmux for non-interactive subcommands and info flags
    if test (count $argv) -ge 1
        switch "$argv[1]"
            case update mcp config
                command claude $argv
                return
            case --help -h --version -v
                command claude $argv
                return
        end
    end

    set -gx CLAUDE_MONITOR_ID $next

    # Inject --dangerously-skip-permissions when running inside a devcontainer
    set -l claude_args $argv
    if set -q DEVCONTAINER
        set claude_args --dangerously-skip-permissions $argv
    end

    set -l short_cwd (string replace "$HOME" "~" "$PWD")
    set -l win_title "[$next] $short_cwd"

    if not set -q TMUX
        # Not in tmux — create a detached session, send claude into it, attach
        set -l sess_name "claude-$next"
        # Propagate Ghostty env into tmux server for terminal detection in hooks
        if set -q GHOSTTY_RESOURCES_DIR
            tmux set-environment -g GHOSTTY_RESOURCES_DIR "$GHOSTTY_RESOURCES_DIR" 2>/dev/null
        end
        tmux new-session -d -s $sess_name -x (tput cols) -y (tput lines)
        # Lock window name so automatic-rename doesn't override it
        tmux set-option -wt $sess_name automatic-rename off
        tmux rename-window -t $sess_name "$win_title"
        # Propagate window name to Ghostty title bar (prefixed with "tmux ")
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        # Send the command into the new session (fish shell inside tmux)
        # Forward GHOSTTY_RESOURCES_DIR so monitor.sh detects the correct terminal
        set -l env_setup "set -gx CLAUDE_MONITOR_ID $next"
        if set -q GHOSTTY_RESOURCES_DIR
            set env_setup "$env_setup; set -gx GHOSTTY_RESOURCES_DIR '$GHOSTTY_RESOURCES_DIR'"
        end
        tmux send-keys -t $sess_name "$env_setup; command claude $claude_args" Enter
        tmux attach-session -t $sess_name
    else
        # Already in tmux — rename current window and run directly
        tmux set-option -w automatic-rename off
        tmux rename-window "$win_title"
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        command claude $claude_args
    end
end
