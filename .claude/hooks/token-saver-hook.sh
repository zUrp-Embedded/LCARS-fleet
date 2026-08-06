#!/bin/bash
#
#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: token-saver-hook.sh
#     |  |________|  | AUTHOR: STARFLEET
#     |   ________   | SYSTEM: LCARS-FLEET
#     |  |  v1.0  |  | STATUS: OPERATIONAL
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     +-----------------------------------------------------------+
#     | MODULE: TOKEN-SAVER     | SUBSYSTEM: CC RUNTIME / HOOK     |
#     | LICENSE: AGPL-3         | STARDATE: 2026.217               |
#     +-------------------------+---------------------------------+
#     |                                                           |
#     |  Shim PreToolUse : resout la brique et lui passe stdin.   |
#     |  Les hooks sont deployes dans ~/.claude/hooks/, la brique |
#     |  vit dans l'arbre — ce fichier fait le pont.              |
#     |                                                           |
#     +-----------------------------------------------------------+
#
#     [FR]
#     Trouve fleet/.../vendor/token_saver/lcars_hook.py et le lance.
#     FAIL-OPEN partout : brique absente, python3 absent, erreur => la
#     commande passe INTACTE. Un hook casse bloque le travail de l'agent.
#
#         Ring:    CC Runtime (hook — PreToolUse, matcher: Bash)
#         Input:   stdin JSON (tool_name, tool_input.command, session_id)
#         Output:  hookSpecificOutput.updatedInput, ou rien (passthrough)
#
set -u

# Coupe franche, avant meme de chercher la brique.
case "${LCARS_TOKEN_SAVER:-}" in
    0|off|false|no|OFF|FALSE|NO) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

# Resolution — du plus explicite au plus devine. Premier trouve gagne.
_candidats=(
    "${LCARS_TOKEN_SAVER_HOME:-}"
    "/opt/lcars/fleet/vendor/token_saver"
    "/opt/lcars/fleet/runtime/vendor/token_saver"
    "/local/LCARS_v2/fleet/vendor/token_saver"
    "/local/LCARS/fleet/runtime/vendor/token_saver"
    "${LCARS_ROOT:-}/fleet/vendor/token_saver"
    "${LCARS_ROOT:-}/fleet/runtime/vendor/token_saver"
)

_hook=""
for _c in "${_candidats[@]}"; do
    [ -n "$_c" ] || continue
    if [ -f "$_c/lcars_hook.py" ]; then
        _hook="$_c/lcars_hook.py"
        break
    fi
done

# Brique introuvable : on s'efface. C'est le cas nominal tant que le
# Dockerfile ne la copie pas dans l'image.
[ -n "$_hook" ] || exit 0

exec python3 "$_hook"
