#!/bin/bash
# mock_claude.bash — Mock claude CLI for bats testing
#
# PURPOSE : Intercept `claude -p` (headless dispatch) calls.
# LOG     : All calls logged to $BATS_TEST_TMPDIR/claude.log

claude() {
    echo "MOCK_CLAUDE: $*" >> "${BATS_TEST_TMPDIR}/claude.log"

    # Simulate headless mode: read stdin, produce output
    if [[ "$1" == "-p" ]]; then
        # Consume stdin if piped
        cat > /dev/null 2>&1 || true
        echo "Mock headless output"
        return 0
    fi

    # Any other subcommand
    return 0
}

export -f claude
