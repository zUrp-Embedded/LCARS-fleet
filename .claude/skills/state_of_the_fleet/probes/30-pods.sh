#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/30-pods.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 30 : qui tourne, et ce que la fleet a vu passer
#
# The fleet is socket-only: the live snapshot is served by the observation deck over its per-human
# AF_UNIX socket at `/api/pods`. There is no longer a second TCP surface to confuse it with, so the
# old API-port 501 "port-guard" — which existed ONLY to prove we were not reading the wrong port —
# has nothing left to guard and is gone. Reaching the deck socket is reaching the one surface.
#
# SCOPE, per starfleet's position: pods are CONTAINERS. Who runs, which role, which project, since
# when. Never what the pod is doing inside its workspace — that belongs to the project's architect.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="pods"
SOCK="$(sotf_obs_sock)"

# ── L'instantane vivant ───────────────────────────────────────────────────────────────────────────
# `Spawner.list_pods/0` behind the endpoint — a LIVE snapshot, not an event replay, because `pod.*`
# only emits terminals (completed/failed/drift) and would never describe a pod that is merely alive.
probe_live() {
  sotf_skip_no_fleet "pods.live" "$PLANE" "sonde sans objet" && return
  if ! http_probe "http://localhost/api/pods" 6 "$SOCK"; then
    emit "pods.live" "$PLANE" "unreachable" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
      "curl absent" "Aveugle sur les pods : aucune conclusion possible, ni presence ni absence."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "pods.live" "$PLANE" "degraded" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
      "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
      "Un endpoint muet n'est PAS zero pod : je ne sais pas combien tournent."
    return
  fi
  if [[ -z "${SOTF_HAS_JQ:-}" ]]; then
    emit "pods.live" "$PLANE" "unknown" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
      "$(trim "$SOTF_HTTP_BODY" 300)" "Sans jq je ne sais pas compter ni detailler : la reponse est la, non lue."
    return
  fi

  local n
  n="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '(.pods // .) | if type=="array" then length else "?" end' 2>/dev/null)"
  if [[ "$n" == "?" || -z "$n" ]]; then
    emit "pods.live" "$PLANE" "unknown" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
      "forme inattendue : $(trim "$SOTF_HTTP_BODY" 200)" \
      "Reponse non decoupable : ZERO pod extrait n'est pas zero pod qui tourne."
    return
  fi

  # Zero pods is a legitimate state (an idle fleet), NOT a fault — hence `operational` with the count
  # in the evidence. Calling it `degraded` would make an idle box permanently red.
  emit "pods.live" "$PLANE" "operational" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
    "$n pod(s) vivant(s)" \
    "Un pod VIVANT n'est pas un pod qui travaille : cette sonde ne mesure pas le progres, seulement la presence."

  # One line per pod: role, project, id. The CONTAINER, never the content.
  local id role project state
  while IFS=$'\t' read -r id role project state; do
    [[ -z "$id" ]] && continue
    emit "pods.pod.$id" "$PLANE" "operational" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/pods" \
      "role=${role:-?} projet=${project:-aucun} etat=${state:-?}" \
      "Presence et identite declarees par la fleet. Ni l'avancement de son travail, ni sa sante interne."
  done < <(printf '%s' "$SOTF_HTTP_BODY" \
    | jq -r '((.pods // .)[]? | [(.pod_id // .id // "?"), (.role // "?"), (.project // .repo // ""), (.state // .status // "")]) | @tsv' 2>/dev/null)
}

# ── La projection d'evenements ────────────────────────────────────────────────────────────────────
# The ETS projection the ReadModel maintains. Reported as VOLUME per deck, not as content: what a
# gatekeeper decided belongs to its project, not to the front desk.
probe_events() {
  sotf_skip_no_fleet "pods.events" "$PLANE" "sonde sans objet" && return
  if ! http_probe "http://localhost/api/projection" 6 "$SOCK"; then
    emit "pods.events" "$PLANE" "unreachable" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/projection" \
      "curl absent" "Aveugle sur le flux d'evenements."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "pods.events" "$PLANE" "degraded" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/projection" \
      "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
      "Sans projection je ne sais pas si la fleet a vu passer quoi que ce soit."
    return
  fi
  if [[ -z "${SOTF_HAS_JQ:-}" ]]; then
    emit "pods.events" "$PLANE" "unknown" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/projection" \
      "$(trim "$SOTF_HTTP_BODY" 200)" "Sans jq, projection non decoupee."
    return
  fi

  local total decks
  total="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.total // "?"' 2>/dev/null)"
  decks="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '
    [ (.workflow_runs // [] | length | "workflow_runs=\(.)"),
      (.gatekeeper   // [] | length | "gatekeeper=\(.)"),
      (.coordination // [] | length | "coordination=\(.)"),
      (.diagnostics  // [] | length | "diagnostics=\(.)"),
      (.stream       // [] | length | "stream=\(.)") ] | join(" ")' 2>/dev/null)"

  # A projection that is empty since boot is NOT a fault: the bus is a stream, not a store, and the
  # decks start empty. Saying `degraded` on a freshly booted fleet would be a false alarm every time.
  emit "pods.events" "$PLANE" "operational" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/projection" \
    "total=$total · $decks" \
    "Compte ce que la fleet a DIFFUSE depuis son boot. Le bus est lossy par doctrine : un compteur bas ne prouve pas l'inaction."

  # The diagnostics deck is the one that carries boot/oauth/mcp/sdk/signal/git events — the closest
  # thing the runtime has to "something went wrong". Non-empty is worth a look, never a verdict.
  local diag_n
  diag_n="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.diagnostics // [] | length' 2>/dev/null)"
  if [[ "${diag_n:-0}" -gt 0 ]]; then
    emit "pods.diagnostics_deck" "$PLANE" "unknown" "hote-socket" \
      "curl --unix-socket $SOCK http://localhost/api/projection | jq .diagnostics" \
      "$diag_n evenement(s) sur le deck diagnostics (boot/oauth/mcp/sdk/signal/git)" \
      "Un evenement de diagnostic n'est pas une panne : c'est un endroit ou regarder. Leur CONTENU se lit avec 'diag'."
  fi
}

# ── Runner ────────────────────────────────────────────────────────────────────────────────────────
sotf_init
probe_live
probe_events
exit "$(sotf_exit_code)"
