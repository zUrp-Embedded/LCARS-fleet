#!/bin/bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: install-hooks.sh
#     |  |________|  | AUTHOR: LORDZURP
#     |   ________   | SYSTEM: LCARS-FLEET v5.4
#     |  |  v5.4  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | [ LCARS-FLEET ] COMMAND INTERFACE    [ ACCESS GRANTED ]   |
#     +-----------------------------------------------------------+
#     | MODULE: INSTALL-HOOKS   | SUBSYSTEM: GIT-HOOKS / SETUP    |
#     | LICENSE: AGPL-3         | STARDATE: 2026.087              |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Installs fleet git hooks into .git/hooks/.               |
#     |  TPD protection, QA gate, GO-7 enforcement.               |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Installe les git hooks fleet dans .git/hooks/ d'un ou plusieurs repos.
#     Protection TPD, gate QA, enforcement GO-7 headers.
#
#     [EN]
#     NAME
#         install-hooks.sh — install fleet git hooks into .git/hooks/
#
#     INTERFACE
#         Ring:    0 (gate)
#         Input:   repo path (default: current or LCARS dev clone), hook sources
#         Output:  symlinks in .git/hooks/ (pre-commit, pre-push)
#
#     EXIT CODES
#         0    Hooks installed
#         1    No .git/ found
#
# --- END HEADER ---

set -euo pipefail

case "${1:-}" in
    -h|--help)
        echo "Usage: install-hooks.sh [--all-projects <dir>] [<repo-path>]"
        echo "  Sans argument : installe dans le repo courant ou LCARS dev clone"
        echo "  --all-projects <dir> : installe dans tous les repos git sous <dir>"
        exit 0
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR"
HOOKS=("pre-commit" "pre-push" "hook-config.sh")

install_hooks_to() {
    local repo="$1"
    [ -d "$repo/.git" ] || return 1
    local hooks_dir="$repo/.git/hooks"
    echo "Installing fleet git hooks → $hooks_dir"
    for HOOK in "${HOOKS[@]}"; do
        local src="$SRC_DIR/$HOOK"
        local dst="$hooks_dir/$HOOK"
        [[ -f "$src" ]] || { echo "  SKIP: $src not found"; continue; }
        # SYMLINK, not copy: the versioned source stays the ONLY file. A local "hotfix"
        # of .git/hooks would edit the source through the link and show up in git status —
        # the copy+hotfix divergence (observed April 2026) becomes impossible.
        if [[ -f "$dst" && ! -L "$dst" ]]; then
            cp "$dst" "$dst.bak"
        fi
        ln -sfn "$src" "$dst"
        [[ -x "$src" ]] || chmod +x "$src"
        echo "  [linked] $HOOK"
    done
}

if [[ "${1:-}" == "--all-projects" ]]; then
    PROJECTS_DIR="${2:-/home/projects}"
    for repo_dir in "$PROJECTS_DIR"/*/; do
        [ -d "$repo_dir/.git" ] || continue
        install_hooks_to "$repo_dir"
    done
    echo "Done (all projects)."
elif [[ "${1:-}" == "--repo" ]]; then
    REPO="${2:?usage: install-hooks.sh --repo <path>}"
    install_hooks_to "$REPO"
    echo "Done."
else
    REPO="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")"
    [[ -z "$REPO" ]] && { echo "ERROR: not in a git repo and --repo not specified" >&2; exit 1; }
    install_hooks_to "$REPO"
    echo "Done."
fi
