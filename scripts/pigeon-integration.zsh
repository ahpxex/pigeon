
# ---------------------------------------------------------------------------
# Pigeon: terminal-native agent.
#
# Appended to Ghostty's zsh shell integration at app build time. When a
# command line's first word is not a real command, zsh calls
# command_not_found_handler — we treat the whole line as natural language
# and stream the built-in agent's answer straight into the terminal.
# Real commands are untouched: the shell resolved them before we ever run.
# ---------------------------------------------------------------------------
if [[ -n "$PIGEON_AGENT_PORT" ]]; then
    command_not_found_handler() {
        # Reconstruct the original line as best zsh lets us.
        local prompt="$*"

        # Heuristic guard: single short token with no spaces is almost
        # certainly a typo'd command, not natural language.
        if [[ "$prompt" != *" "* && ${#prompt} -le 12 && "$prompt" == [a-zA-Z0-9_-]* ]]; then
            print -u2 "zsh: command not found: $1"
            return 127
        fi

        command curl -sN --max-time 300 \
            -X POST "http://127.0.0.1:${PIGEON_AGENT_PORT}/ask" \
            -H "Content-Type: text/plain; charset=utf-8" \
            -H "X-Pigeon-Cwd: $PWD" \
            --data-binary "$prompt"
        return 0
    }
fi
