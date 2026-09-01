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
#     | LICENSE: AGPL-3         | STARDATE: 2026.240               |
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
set -u          # PAS -e : un hook qui meurt bloque la session de l'humain.

# Coupe franche, avant meme de chercher la brique.
#
# Insensible a la CASSE, et ce n'etait pas le cas : la liste exacte `off|OFF` laissait passer `Off`,
# qui traversait le shim, lancait python3, et se faisait couper par `adapter.is_enabled()` dont le
# `.lower()`, lui, le reconnaissait. Bon resultat, un interpreteur gaspille par commande — soit
# exactement le cout que ce shim existe pour eviter.
#
# Le vocabulaire est ferme des deux cotes (cf. `_OFF_VALUES` / `_ON_VALUES` dans adapter.py) : un
# mot inconnu n'est PAS un ON silencieux, il coupe et le dit. Ce shim ne peut pas crier (il tourne
# avant tout, dans un hook) : il laisse donc passer l'inconnu jusqu'a l'adapter, qui coupera ET
# parlera. Le seul cout est un processus, sur une valeur qui est de toute facon une faute de frappe.
_ts_switch=$(printf '%s' "${LCARS_TOKEN_SAVER:-}" | tr '[:upper:]' '[:lower:]')
case "$_ts_switch" in
    0|off|false|no) exit 0 ;;
esac

command -v python3 >/dev/null 2>&1 || exit 0

# Resolution — du plus explicite au plus devine. Premier trouve gagne.
# Les candidats etaient APPARIES (chemin post-demenagement avant chemin pre-) pour survivre a la
# bascule sans etre touches. Le demenagement est fait (2026-08-07) : les trois chemins
# `fleet/runtime/vendor` ne designent plus rien et sont retires. Garder un candidat mort n'est pas
# gratuit — il fait croire a une couverture qu'il n'assure plus.
_candidats=(
    "${LCARS_TOKEN_SAVER_HOME:-}"
    "/opt/lcars/fleet/vendor/token_saver"
    "/opt/lcars/runtime/fleet/vendor/token_saver"
    "${LCARS_ROOT:-}/fleet/vendor/token_saver"
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
