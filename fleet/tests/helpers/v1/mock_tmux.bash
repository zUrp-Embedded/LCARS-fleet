#!/bin/bash
# mock_tmux.bash — Mock tmux for bats testing
#
# PURPOSE : Intercept tmux calls, log them, return predictable results.
# USAGE   : source this file, then scripts that call tmux get the mock.
# LOG     : All calls logged to $BATS_TEST_TMPDIR/tmux.log

tmux() {
    local cmd="${1:-}"
    echo "MOCK_TMUX: $*" >> "${BATS_TEST_TMPDIR}/tmux.log"

    case "$cmd" in
        has-session)
            # -t <session> : return 0 if MOCK_TMUX_SESSIONS contains it
            local target="${3:-}"
            if [[ " ${MOCK_TMUX_SESSIONS:-fleet} " == *" $target "* ]]; then
                return 0
            else
                return 1
            fi
            ;;
        send-keys)
            # Logged, no action
            return 0
            ;;
        list-panes)
            # Return fixture pane list
            echo "starfleet %0 [200x50]"
            echo "architect %1 [200x50]"
            echo "engineer %2 [200x50]"
            echo "dev %3 [200x50]"
            return 0
            ;;
        list-sessions)
            echo "fleet: 4 windows"
            return 0
            ;;
        new-window|split-window|select-pane|kill-pane)
            # Logged, no action
            return 0
            ;;
        *)
            # Unknown subcommand — log and succeed
            return 0
            ;;
    esac
}

export -f tmux
export MOCK_TMUX_SESSIONS="${MOCK_TMUX_SESSIONS:-fleet}"
