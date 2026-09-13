#!/usr/bin/env bash
# SOURCE: .claude/skills/state_of_the_fleet/probes/20-fleet.sh
# AUTHOR: starfleet toolkit
# DATE: 2026-07-31
# STATUS: actif — sonde 20 : l'etat du daemon
#
# RELAYS, does not re-implement. `Fleet.API.Readiness.deep/0` already IS an operational read-model
# with a per-subsystem vocabulary and defensive probes (an exception folds into `degraded` rather
# than crashing the endpoint). Re-deriving that state here would create a second truth for one fact
# — the very thing `provision doctor` forbids ("le doctor N'EST PAS un autre code que l'apply").
#
# The fleet is socket-only: these routes are served by the observation deck over its per-human
# AF_UNIX socket, not a TCP port. That removes the old "wrong daemon" caveat entirely — a name
# resolves to ONE path and this operator can only reach their OWN deck.sock, so a 200 here is always
# our fleet, never a neighbour's answered on a mis-derived port.

# ⚠ AUCUN `set -e` ICI, ET C'EST LA DOCTRINE DES SONDES. Une sonde qui meurt n'emet AUCUN verdict :
# son plan disparait du rapport sans que rien ne le signale. Elle doit survivre a ses propres
# echecs pour les DIRE (`unknown`, `degraded`) — c'est precisement ce que la sonde 10 existe pour
# empecher. Pas de `-u` non plus : une variable absente est un fait a rapporter, pas une mort.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="fleet"
SOCK="$(sotf_obs_sock)"

# ── health : Cowboy a-t-il bindé ──────────────────────────────────────────────────────────────────
# The weakest possible signal, and the code says so: 200 "as soon as Cowboy binds", which says
# NOTHING about wiring. Kept because its ABSENCE is informative — no health means no daemon, and
# every probe below is then explained rather than mysterious.
probe_health() {
  # A container where nobody ran `fleet_v2 start` is NOT a degraded fleet — it is a container without a fleet.
  # Measured on a fresh container: no `~/.lcars/run/` at all, and without this branch the run
  # produced five red lines describing a daemon that was never asked to exist. `inactive` is the
  # honest verdict, and it deliberately does not degrade the run.
  if ! sotf_fleet_ever_started; then
    emit "fleet.health" "$PLANE" "inactive" "hote-socket" "test -d $(sotf_run_dir)" \
      "aucune fleet demarree sous cet humain (pas de $(sotf_run_dir)) — endpoint non interroge" \
      "Ne dit rien d'une fleet lancee par un AUTRE humain sur cette machine : chacun a son socket et son repertoire de run."
    return 1
  fi
  # Deck route is `/health` (NOT `/api/health`), reached over the per-human deck socket.
  if ! http_probe "http://localhost/health" 4 "$SOCK"; then
    emit "fleet.health" "$PLANE" "unreachable" "hote-socket" "curl --unix-socket $SOCK http://localhost/health" \
      "curl absent" \
      "Aveugle : sans outil je ne distingue pas un daemon arrete d'une sonde amputee."
    return 1
  fi
  case "$SOTF_HTTP_CODE" in
    2*) emit "fleet.health" "$PLANE" "operational" "hote-socket" "curl --unix-socket $SOCK http://localhost/health" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 120)" \
          "Le deck a bind son socket, RIEN de plus. Un daemon en bonne sante et un daemon vide repondent pareil." ;;
    *)  emit "fleet.health" "$PLANE" "degraded" "hote-socket" "curl --unix-socket $SOCK http://localhost/health" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
          "Un non-2xx sur le health du deck : le daemon a repondu mais mal. Ne dit pas encore quel sous-systeme."
        return 1 ;;
  esac
}

# ── readiness/deep : l'etat par sous-systeme, relaye tel quel ─────────────────────────────────────
# One probe emitted PER SUBSYSTEM, with the daemon's own verdict carried across untouched. The
# vocabulary matches ours because ours was taken from it — `inactive` above all, which is what keeps
# a deliberately-off subsystem from being reported as a fault.
probe_readiness() {
  if ! http_probe "http://localhost/api/readiness/deep" 8 "$SOCK"; then
    emit "fleet.readiness" "$PLANE" "unreachable" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/readiness/deep" \
      "curl absent" "Aveugle sur le cablage du daemon."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "fleet.readiness" "$PLANE" "degraded" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/readiness/deep" \
      "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
      "Un endpoint muet ne dit pas si les sous-systemes vont bien ou si la route a change."
    return
  fi
  if [[ -z "${SOTF_HAS_JQ:-}" ]]; then
    emit "fleet.readiness" "$PLANE" "unknown" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/readiness/deep" \
      "$(trim "$SOTF_HTTP_BODY" 300)" \
      "Sans jq je ne sais pas decouper la reponse par sous-systeme : le detail est la, non lu."
    return
  fi

  local global sub state detail n=0
  global="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.status // .verdict // "?"' 2>/dev/null)"
  emit "fleet.readiness" "$PLANE" \
    "$([[ "$global" == operational ]] && echo operational || echo degraded)" \
    "hote-socket" "curl --unix-socket $SOCK http://localhost/api/readiness/deep" \
    "verdict global du daemon : $global" \
    "Verdict du daemon SUR LUI-MEME. Ne couvre ni la forge, ni les projets, ni le disque."

  # `.subsystems[]` is the daemon's shape; if it ever changes, we say so instead of reporting a
  # silent zero — an empty per-subsystem list would otherwise look like a clean bill of health.
  while IFS=$'\t' read -r sub state detail; do
    [[ -z "$sub" ]] && continue
    n=$((n + 1))
    case "$state" in
      operational|inactive|degraded) : ;;
      *) state="unknown" ;;
    esac
    emit "fleet.subsystem.$sub" "$PLANE" "$state" "hote-socket" \
      "curl --unix-socket $SOCK http://localhost/api/readiness/deep | jq .subsystems" \
      "$(trim "$detail" 200)" \
      "Etat declare par le daemon pour CE sous-systeme. Une sonde interne peut se replier en degraded sur exception : le detail dit laquelle."
  done < <(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.subsystems[]? | [.id, .state, (.detail | tostring)] | @tsv' 2>/dev/null)

  if [[ "$n" -eq 0 ]]; then
    emit "fleet.subsystems" "$PLANE" "unknown" "hote-socket" \
      "curl --unix-socket $SOCK http://localhost/api/readiness/deep | jq '.subsystems[]'" \
      "aucun sous-systeme extrait de la reponse (forme inattendue)" \
      "Zero sous-systeme n'est PAS zero probleme : c'est une reponse que je n'ai pas su lire."
  fi
}

# ── version : quel build sert reellement ──────────────────────────────────────────────────────────
# The question every incident asks second: which code is actually running. `dirty` matters as much
# as the sha — a dirty build means the deployed tree is not any commit.
probe_build() {
  if ! http_probe "http://localhost/api/version" 4 "$SOCK"; then
    emit "fleet.build" "$PLANE" "unreachable" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/version" \
      "curl absent" "Aveugle sur le build servi."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "fleet.build" "$PLANE" "degraded" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/version" \
      "HTTP $SOTF_HTTP_CODE" "Sans version je ne peux rapporter aucun etat a un commit."
    return
  fi
  emit "fleet.build" "$PLANE" "operational" "hote-socket" "curl --unix-socket $SOCK http://localhost/api/version" \
    "$(trim "$SOTF_HTTP_BODY" 250)" \
    "Dit QUEL code tourne, pas s'il est le bon. Un 'dirty' signale un arbre deploye qui n'est aucun commit."
}

# ── Runner ────────────────────────────────────────────────────────────────────────────────────────
sotf_init
if probe_health; then
  probe_readiness
  probe_build
else
  # Nothing below could produce anything but noise, and a probe that emits noise is worse than one
  # that abstains OUT LOUD: `unreachable` with the reason is the honest shape of "not asked".
  # Two distinct reasons not to have measured, and conflating them would hide the interesting one:
  # either no fleet exists here (expected, `inactive`), or one exists and did not answer (`unreachable`).
  if sotf_fleet_ever_started; then
    r="health rouge — sondes suivantes non lancees"; v="unreachable"
  else
    r="aucune fleet demarree ici — sondes suivantes sans objet"; v="inactive"
  fi
  emit "fleet.readiness" "$PLANE" "$v" "hote-socket" "(non lancee)" "$r" \
    "Non mesure. N'affirme rien sur le cablage du daemon."
  emit "fleet.build" "$PLANE" "$v" "hote-socket" "(non lancee)" "$r" \
    "Non mesure. Le build servi reste inconnu."
fi
exit "$(sotf_exit_code)"
