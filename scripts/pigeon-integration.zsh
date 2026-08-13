
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
    # --- prose-aware syntax highlighting -----------------------------------
    # zsh-syntax-highlighting paints any line whose first word isn't a
    # command as an error — but in Pigeon such lines are valid input (they
    # dispatch to the agent). Mute its main highlighter exactly when the
    # dispatch heuristic below would send the line to the agent: real
    # commands keep full highlighting, a short ASCII token (likely a typo'd
    # command) keeps its red, prose gets no paint at all.
    _pigeon_line_is_prose() {
        local buffer="$BUFFER"
        [[ -n "$buffer" ]] || return 1
        local first="${${(z)buffer}[1]}"
        [[ -n "$first" ]] || return 1
        # Env-assignment prefix (FOO=1 cmd) is command syntax.
        [[ "$first" == *=* ]] && return 1
        whence -w -- "$first" &>/dev/null && return 1
        # Mirror of the typo guard in command_not_found_handler.
        if [[ "$buffer" != *" "* && ${#buffer} -le 12 && "$buffer" =~ '^[a-zA-Z0-9._-]+$' ]]; then
            return 1
        fi
        return 0
    }

    # Installed from precmd so it runs after the user's plugins loaded,
    # whatever the sourcing order.
    _pigeon_install_prose_highlighting() {
        add-zsh-hook -d precmd _pigeon_install_prose_highlighting
        (( $+functions[_zsh_highlight] )) || return 0
        if (( $+functions[_zsh_highlight_highlighter_main_predicate] )); then
            functions -c _zsh_highlight_highlighter_main_predicate _pigeon_orig_main_predicate
        fi
        _zsh_highlight_highlighter_main_predicate() {
            _pigeon_line_is_prose && return 1
            if (( $+functions[_pigeon_orig_main_predicate] )); then
                _pigeon_orig_main_predicate
            else
                return 0
            fi
        }
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _pigeon_install_prose_highlighting

    # --- loading spinner ---------------------------------------------------
    # Model latency means 1-3 s of dead air after enter (and again after
    # each tool round). Animate a dim spinner on /dev/tty whenever we're
    # waiting on the stream; it never touches the stream itself, so
    # nothing pollutes the captured output. The 0.15 s initial delay
    # keeps it invisible during rapid line bursts.
    _pigeon_spin_loop() {
        local -a frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=1
        command sleep 0.15
        while :; do
            print -n -- $'\r\e[2m'"${frames[i]}"$'\e[0m' > /dev/tty
            (( i = i % $#frames + 1 ))
            command sleep 0.08
        done
    }
    # The spinner replaces the cursor: hide it while streaming (the
    # blinking block next to the animation reads as noise), restore it
    # whenever the user needs to type or the stream ends.
    _pigeon_spinner_start() {
        print -n -- $'\e[?25l' > /dev/tty
        _pigeon_spin_loop &!
        typeset -g _pigeon_spinner_pid=$!
    }
    _pigeon_spinner_stop() {
        [[ -n "${_pigeon_spinner_pid:-}" ]] || return 0
        kill "$_pigeon_spinner_pid" 2>/dev/null
        _pigeon_spinner_pid=""
        print -n -- $'\r\e[2K' > /dev/tty
    }
    _pigeon_stream_cleanup() {
        _pigeon_spinner_stop
        print -n -- $'\e[?25h' > /dev/tty
    }

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
        setopt localoptions no_notify no_monitor localtraps
        trap '_pigeon_stream_cleanup' EXIT INT TERM
        _pigeon_spinner_start
        command curl -sN --max-time 600 \
            -X POST "http://127.0.0.1:${PIGEON_AGENT_PORT}/ask" \
            -H "Content-Type: text/plain; charset=utf-8" \
            -H "Authorization: Bearer ${PIGEON_AGENT_TOKEN}" \
            -H "X-Pigeon-Cwd: $PWD" \
            --data-binary "$prompt" \
        | while IFS= read -r line || [[ -n "$line" ]]; do
            _pigeon_spinner_stop
            if [[ "$line" == "${confirm_prefix}"* ]]; then
                payload="${line#${confirm_prefix}}"
                confirm_id="${payload%%$'\1'*}"
                display="${payload#*$'\1'}"
                answer=n
                print -n -- $'\e[?25h\e[33m'"⚠ ${display} — allow? [y/N] "$'\e[0m' > /dev/tty
                read -q answer < /dev/tty || answer=n
                print -n -- $'\n\e[?25l' > /dev/tty
                command curl -s -o /dev/null --max-time 10 \
                    -X POST "http://127.0.0.1:${PIGEON_AGENT_PORT}/confirm" \
                    -H "Content-Type: application/json" \
                    -H "Authorization: Bearer ${PIGEON_AGENT_TOKEN}" \
                    --data-binary "{\"id\":\"${confirm_id}\",\"allow\":$([[ "$answer" == [yY] ]] && print -n true || print -n false)}"
            else
                print -r -- "$line"
            fi
            # Waiting again: next tokens may be a model round away.
            _pigeon_spinner_start
        done
        _pigeon_stream_cleanup
        return 0
    }
fi
