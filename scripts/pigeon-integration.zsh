
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

        # Heuristic guard: a single short token made ENTIRELY of ASCII
        # command characters is almost certainly a typo'd command, not
        # natural language. Anything containing CJK or other non-ASCII
        # is a sentence — Chinese needs no spaces to be one ("3000端口是啥"
        # must reach the agent, "gti" must not).
        if [[ "$prompt" != *" "* && ${#prompt} -le 12 && "$prompt" =~ '^[a-zA-Z0-9._-]+$' ]]; then
            print -u2 "zsh: command not found: $1"
            return 127
        fi

        # Read the stream line by line: mutating tool calls arrive as a
        # sentinel line (SOH-framed) that pauses the agent until we POST
        # the user's y/N back to /confirm. Everything else prints as-is.
        # (Output is line-buffered anyway — the app renders markdown per
        # line — so line-wise reading costs nothing.)
        local confirm_prefix=$'\1PIGEON_CONFIRM\1'
        local line payload confirm_id display answer
        command curl -sN --max-time 600 \
            -X POST "http://127.0.0.1:${PIGEON_AGENT_PORT}/ask" \
            -H "Content-Type: text/plain; charset=utf-8" \
            -H "Authorization: Bearer ${PIGEON_AGENT_TOKEN}" \
            -H "X-Pigeon-Cwd: $PWD" \
            --data-binary "$prompt" \
        | while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${confirm_prefix}"* ]]; then
                payload="${line#${confirm_prefix}}"
                confirm_id="${payload%%$'\1'*}"
                display="${payload#*$'\1'}"
                answer=n
                print -n -- $'\e[33m'"⚠ ${display} — allow? [y/N] "$'\e[0m' > /dev/tty
                read -q answer < /dev/tty || answer=n
                print > /dev/tty
                command curl -s -o /dev/null --max-time 10 \
                    -X POST "http://127.0.0.1:${PIGEON_AGENT_PORT}/confirm" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer ${PIGEON_AGENT_TOKEN}" \
                    --data-binary "{\"id\":\"${confirm_id}\",\"allow\":$([[ "$answer" == [yY] ]] && print -n true || print -n false)}"
            else
                print -r -- "$line"
            fi
        done
        return 0
    }
fi
