#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/10-instruments.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 10 : de quoi je dispose reellement
#
# ALWAYS FIRST, and it is not a formality. A diagnostic that assumes its own channels are alive
# reports nothing and does not say so. Measured on a live starfleet: its MCP bridge was dead (no
# python3 in the sandbox) and NOT ONE `mcp__fleet__*` tool was loaded — the pod could not have
# answered a single question about the fleet, and nothing in it was designed to notice.
#
# This probe never concludes anything about the fleet, the forge or a project. It measures ONE
# thing: where my blind spots are. Everything it finds `unreachable` downstream is explained here.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="instruments"

# ── Context: pod or host ──────────────────────────────────────────────────────────────────────────
# The toolkit is written FOR a pod but must stay runnable on the host (that is where it is developed
# and where an operator may want it). The distinction is not cosmetic: half the probes below are
# meaningless outside a pod, and reporting them `degraded` on a host would be a false alarm. They
# report `inactive` instead — deliberately off, expected, not a fault.
sotf_in_pod() { [[ -n "${LCARS_POD_ID:-}" ]]; }

probe_context() {
  local ev
  if sotf_in_pod; then
    ev="pod ${LCARS_POD_ID} role=${LCARS_ROLE:-?} home=${LCARS_POD_HOME:-$HOME} uid=$(sotf_uid)"
  else
    ev="hors pod (LCARS_POD_ID absent) — hote, uid=$(sotf_uid), home=$HOME"
  fi
  emit "instruments.context" "$PLANE" "operational" "local" \
    'test -n "$LCARS_POD_ID"' \
    "$ev" \
    "Dit OU je tourne, pas si ce qui m'entoure va bien. Un contexte identifie ne prouve aucun etat."
}

# ── Shell tooling ─────────────────────────────────────────────────────────────────────────────────
# curl/git/jq are the toolkit's own dependencies. perl is the fallback transport for the MCP socket
# (measured present in a pod, and the only way that pod could talk to central once its bridge died).
# A missing tool is `degraded` HERE — the instrument set is incomplete — and becomes `unreachable`
# in whichever probe needed it. Two verdicts for one fact, and that is correct: my instruments are
# broken (a finding), so that measurement could not be taken (a blind spot).
probe_shell_tools() {
  # The required list is what the TOOLKIT ITSELF calls, not a wish list. It gained the coreutils the
  # hard way: a self-referential `grep` symlink in a test harness made the bridge probe report
  # `unknown` — honestly, it refused to conclude — but NOTHING explained why, because `grep` was not
  # declared a dependency. An unexplained blind spot is half a diagnostic. Anything this toolkit
  # shells out to belongs here, or its absence surfaces as an unattributable `unknown`.
  local need="curl git jq dirname date id tr grep head" opt="perl openssl awk sed" missing="" present="" o
  for o in $need; do have "$o" && present="$present $o" || missing="$missing $o"; done
  local optmissing=""
  for o in $opt; do have "$o" && present="$present $o" || optmissing="$optmissing $o"; done

  local verdict="operational" ev="presents :$present"
  [[ -n "$optmissing" ]] && ev="$ev · absents (optionnels) :$optmissing"
  if [[ -n "$missing" ]]; then
    verdict="degraded"
    ev="MANQUANTS (requis) :$missing · $ev"
  fi

  emit "instruments.shell_tools" "$PLANE" "$verdict" "local" \
    "command -v $need $opt" \
    "$ev" \
    "Ne dit rien de la fleet. Un outil absent = une mesure que je ne pourrai PAS prendre, pas une panne."
}

# ── Fleet endpoints ───────────────────────────────────────────────────────────────────────────────
# The URL's ORIGIN is part of the evidence. Derived from the UID, it is a guess that holds only
# while the pod inherits the human's UID; declared by env, it is a fact. A reader must be able to
# tell which, because a wrong guess probes the NEIGHBOUR's fleet and reports it as ours — a lie that
# looks perfectly healthy.
probe_endpoints() {
  local api obs origin
  api="$(sotf_api_url)"; obs="$(sotf_obs_url)"; origin="$(sotf_url_origin)"

  local u name
  for name in api obs; do
    [[ "$name" == api ]] && u="$api/api/health" || u="$obs/health"
    if ! http_probe "$u" 3; then
      emit "instruments.endpoint_$name" "$PLANE" "unreachable" "hote-http" \
        "curl $u" "curl absent" \
        "Aveugle sur cet endpoint : je ne peux pas distinguer une fleet morte d'une sonde sans outil."
      continue
    fi
    case "$SOTF_HTTP_CODE" in
      2*) emit "instruments.endpoint_$name" "$PLANE" "operational" "hote-http" \
            "curl $u" "HTTP $SOTF_HTTP_CODE · url $origin" \
            "Prouve qu'un serveur repond a cette adresse. Ne prouve PAS que c'est MA fleet si l'url est derivee." ;;
      000) emit "instruments.endpoint_$name" "$PLANE" "degraded" "hote-http" \
            "curl $u" "aucune reponse ($SOTF_HTTP_BODY) · url $origin" \
            "Sans reponse je ne distingue pas fleet arretee, mauvais port derive, ou reseau coupe." ;;
      *) emit "instruments.endpoint_$name" "$PLANE" "degraded" "hote-http" \
            "curl $u" "HTTP $SOTF_HTTP_CODE · $SOTF_HTTP_BODY · url $origin" \
            "Un code non-2xx sur health peut venir d'un autre service ecoutant sur ce port derive." ;;
    esac
  done
}

# ── MCP socket ────────────────────────────────────────────────────────────────────────────────────
# The pod's nominal channel to central. Only its EXISTENCE and type are checked: talking to it means
# emitting a JSON-RPC frame, which belongs to a probe that declares it, not to the inventory.
probe_mcp_socket() {
  local sock="${LCARS_FLEET_MCP_SOCKET:-}"
  if ! sotf_in_pod; then
    emit "instruments.mcp_socket" "$PLANE" "inactive" "local" \
      'test -S "$LCARS_FLEET_MCP_SOCKET"' "hors pod — pas de socket MCP attendue" \
      "Non applicable hors pod. Ne dit rien de la socket d'un pod reel."
    return
  fi
  if [[ -z "$sock" ]]; then
    emit "instruments.mcp_socket" "$PLANE" "degraded" "local" \
      'test -n "$LCARS_FLEET_MCP_SOCKET"' "var LCARS_FLEET_MCP_SOCKET absente de l'env du pod" \
      "Ne dit pas si central tourne : dit que CE pod n'a pas recu l'adresse pour lui parler."
  elif [[ -S "$sock" ]]; then
    emit "instruments.mcp_socket" "$PLANE" "operational" "local" \
      "test -S $sock" "socket presente : $sock" \
      "Une socket presente n'est pas une socket qui repond. Le dialogue est teste ailleurs."
  else
    emit "instruments.mcp_socket" "$PLANE" "degraded" "local" \
      "test -S $sock" "chemin declare mais absent ou non-socket : $sock" \
      "Peut venir d'un central arrete comme d'un mount manquant : cette sonde ne les separe pas."
  fi
}

# ── MCP bridge interpreter ────────────────────────────────────────────────────────────────────────
# The single most expensive failure measured to date, and the cheapest to detect: `.mcp-fleet.json`
# declares a command, the command names an interpreter, the interpreter is absent from the image, so
# no `mcp__fleet__*` tool ever loads. The pod boots looking healthy and is mute. We parse the
# declared command and check the interpreter it names — no hardcoded "python3", because the day the
# bridge is ported the check must follow without an edit.
probe_mcp_bridge() {
  local cfg="${LCARS_POD_HOME:-$HOME}/.mcp-fleet.json"
  if ! sotf_in_pod; then
    emit "instruments.mcp_bridge" "$PLANE" "inactive" "local" \
      "read $cfg" "hors pod — pas de bridge MCP attendu" \
      "Non applicable hors pod."
    return
  fi
  if [[ ! -r "$cfg" ]]; then
    emit "instruments.mcp_bridge" "$PLANE" "degraded" "local" \
      "read $cfg" "declaration MCP absente : $cfg" \
      "Sans declaration je ne sais pas quel interpreteur serait requis : je ne peux pas dire pourquoi le canal manque."
    return
  fi
  local cmd interp
  if [[ -n "${SOTF_HAS_JQ:-}" ]]; then
    cmd="$(jq -r '.. | objects | select(has("command")) | [.command] + (.args // []) | join(" ")' "$cfg" 2>/dev/null | head -1)"
  else
    cmd="$(grep -o '"command"[^,]*' "$cfg" | head -1)"
  fi
  # The interpreter is the first token that looks like a program name, `exec`/`bash -c` skipped.
  interp="$(printf '%s\n' "$cmd" | tr ' ' '\n' | grep -vE '^(bash|sh|-c|exec|"|)$' | head -1)"
  interp="${interp%%[[:space:]]*}"

  if [[ -z "$interp" ]]; then
    emit "instruments.mcp_bridge" "$PLANE" "unknown" "local" \
      "jq .command $cfg" "commande declaree illisible : $(trim "$cmd" 120)" \
      "Je n'ai pas su extraire l'interpreteur : ni presence ni absence prouvee."
  elif have "$interp"; then
    emit "instruments.mcp_bridge" "$PLANE" "operational" "local" \
      "command -v $interp" "interpreteur present : $interp" \
      "Un interpreteur present ne prouve pas que le bridge parle : le script peut echouer plus loin."
  else
    emit "instruments.mcp_bridge" "$PLANE" "degraded" "local" \
      "command -v $interp" "interpreteur ABSENT : $interp (declare par $cfg)" \
      "Cause certaine d'un canal MCP muet. N'exclut pas qu'un AUTRE defaut existe en plus."
  fi
}

# ── Runner ────────────────────────────────────────────────────────────────────────────────────────
sotf_init
probe_context
probe_shell_tools
probe_endpoints
probe_mcp_socket
probe_mcp_bridge
exit "$(sotf_exit_code)"
