#!/bin/bash
# mock_yq.bash — Mock yq for bats testing
#
# PURPOSE : Intercept yq calls, return fixture data.
#           Used by scripts that call yq directly (not via fleet-env.sh
#           functions, which are already mocked in mock_fleet_env.bash).
# LOG     : Unhandled queries logged to $BATS_TEST_TMPDIR/yq.log

yq() {
    local query=""
    local file=""

    # yq is typically called as: yq '<query>' <file>
    # or via _yq wrapper:        yq '<query>' "$FLEET_YAML"
    # Parse arguments: last arg is the file, everything else is the query
    if [[ $# -ge 2 ]]; then
        file="${!#}"           # last argument
        query="${*:1:$#-1}"   # everything except last
    elif [[ $# -eq 1 ]]; then
        query="$1"
        file=""
    fi

    # Passthrough: manifest.yaml queries use real yq (build-sp.sh manifest-driven)
    if [[ "$file" == *"manifest.yaml" && -f "$file" ]]; then
        command yq "$query" "$file"
        return $?
    fi

    # Common queries from fleet scripts
    case "$query" in
        *".fleet.paths.lcars_root"*)     echo "/local/LCARS" ;;
        *".fleet.paths.homes_root"*)     echo "/home" ;;
        *".fleet.paths.handoffs"*)       echo "" ;;  # handoffs computed from FLEET_WORKDIR, not YAML
        *".fleet.paths.fleet_state"*)    echo "/home/fleet-state" ;;
        *".fleet.paths.ready_room"*)     echo "/home/ready-room" ;;
        *".fleet.runtime.tmux_socket"*)  echo "/tmp/fleet-tmux.sock" ;;
        *".fleet.runtime.hub_port"*)     echo "8765" ;;
        *".spool.root"*)                 echo "/var/spool/fleet" ;;
        *".fleet.identity.fleet_user"*)  echo "testuser" ;;
        *".fleet.repo"*)                 echo "testuser/LCARS-test" ;;
        *".instances[].role"*)           echo -e "starfleet\narchitect\nengineer\ndev\nqualifier\nreviewer" ;;
        *".instances | keys"*)           echo -e "0\n1\n2\n3\n4\n5" ;;
        *)
            echo "MOCK_YQ_UNHANDLED: query=[$query] file=[$file]" >> "${BATS_TEST_TMPDIR:-/tmp}/yq.log"
            echo "null"
            return 0
            ;;
    esac
}

export -f yq
