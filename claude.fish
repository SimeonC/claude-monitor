function claude --wraps=claude --description 'Claude Code with tmux session management'
    # Read + increment counter (resets on reboot via $TMPDIR)
    set -l counter_file "$TMPDIR/claude_monitor_counter"
    set -l next 1
    if test -f "$counter_file"
        set next (math (cat "$counter_file") + 1)
    end
    echo $next >"$counter_file"

    set -gx CLAUDE_MONITOR_ID $next

    set -l short_cwd (string replace "$HOME" "~" "$PWD")
    set -l win_title "[$next] $short_cwd"

    if not set -q TMUX
        # Not in tmux — create a detached session, send claude into it, attach
        set -l sess_name "claude-$next"
        tmux new-session -d -s $sess_name -x (tput cols) -y (tput lines)
        # Lock window name so automatic-rename doesn't override it
        tmux set-option -wt $sess_name automatic-rename off
        tmux rename-window -t $sess_name "$win_title"
        # Propagate window name to Ghostty title bar (prefixed with "tmux ")
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        # Send the command into the new session (fish shell inside tmux)
        tmux send-keys -t $sess_name "set -gx CLAUDE_MONITOR_ID $next; command claude $argv" Enter
        tmux attach-session -t $sess_name
    else
        # Already in tmux — rename current window and run directly
        tmux set-option -w automatic-rename off
        tmux rename-window "$win_title"
        tmux set-option -g set-titles on 2>/dev/null
        tmux set-option -g set-titles-string "tmux #W" 2>/dev/null
        command claude $argv
    end
end
