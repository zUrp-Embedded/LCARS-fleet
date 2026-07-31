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
# We add exactly one thing the endpoint cannot provide: the knowledge that we may be asking the
# WRONG daemon. The URL can be derived from a UID, and a derived URL that lands on a neighbour's
# fleet answers 200 with somebody else's truth.

SOTF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SOTF_DIR/lib.sh"

PLANE="fleet"
API="$(sotf_api_url)"
ORIGIN="$(sotf_url_origin)"

# ── health : Cowboy a-t-il bindé ──────────────────────────────────────────────────────────────────
# The weakest possible signal, and the code says so: 200 "as soon as Cowboy binds", which says
# NOTHING about wiring. Kept because its ABSENCE is informative — no health means no daemon, and
# every probe below is then explained rather than mysterious.
probe_health() {
  if ! http_probe "$API/api/health" 4; then
    emit "fleet.health" "$PLANE" "unreachable" "hote-http" "curl $API/api/health" \
      "curl absent" \
      "Aveugle : sans outil je ne distingue pas un daemon arrete d'une sonde amputee."
    return 1
  fi
  case "$SOTF_HTTP_CODE" in
    2*) emit "fleet.health" "$PLANE" "operational" "hote-http" "curl $API/api/health" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 120) · url $ORIGIN" \
          "Cowboy a binde son port, RIEN de plus. Un daemon en bonne sante et un daemon vide repondent pareil." ;;
    *)  emit "fleet.health" "$PLANE" "degraded" "hote-http" "curl $API/api/health" \
          "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200) · url $ORIGIN" \
          "Ne separe pas 'daemon arrete' de 'mauvais port derive' : cf. l'origine de l'url ci-dessus."
        return 1 ;;
  esac
}

# ── readiness/deep : l'etat par sous-systeme, relaye tel quel ─────────────────────────────────────
# One probe emitted PER SUBSYSTEM, with the daemon's own verdict carried across untouched. The
# vocabulary matches ours because ours was taken from it — `inactive` above all, which is what keeps
# a deliberately-off subsystem from being reported as a fault.
probe_readiness() {
  if ! http_probe "$API/api/readiness/deep" 8; then
    emit "fleet.readiness" "$PLANE" "unreachable" "hote-http" "curl $API/api/readiness/deep" \
      "curl absent" "Aveugle sur le cablage du daemon."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "fleet.readiness" "$PLANE" "degraded" "hote-http" "curl $API/api/readiness/deep" \
      "HTTP $SOTF_HTTP_CODE · $(trim "$SOTF_HTTP_BODY" 200)" \
      "Un endpoint muet ne dit pas si les sous-systemes vont bien ou si la route a change."
    return
  fi
  if [[ -z "${SOTF_HAS_JQ:-}" ]]; then
    emit "fleet.readiness" "$PLANE" "unknown" "hote-http" "curl $API/api/readiness/deep" \
      "$(trim "$SOTF_HTTP_BODY" 300)" \
      "Sans jq je ne sais pas decouper la reponse par sous-systeme : le detail est la, non lu."
    return
  fi

  local global sub state detail n=0
  global="$(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.status // .verdict // "?"' 2>/dev/null)"
  emit "fleet.readiness" "$PLANE" \
    "$([[ "$global" == operational ]] && echo operational || echo degraded)" \
    "hote-http" "curl $API/api/readiness/deep" \
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
    emit "fleet.subsystem.$sub" "$PLANE" "$state" "hote-http" \
      "curl $API/api/readiness/deep | jq .subsystems" \
      "$(trim "$detail" 200)" \
      "Etat declare par le daemon pour CE sous-systeme. Une sonde interne peut se replier en degraded sur exception : le detail dit laquelle."
  done < <(printf '%s' "$SOTF_HTTP_BODY" | jq -r '.subsystems[]? | [.id, .state, (.detail | tostring)] | @tsv' 2>/dev/null)

  if [[ "$n" -eq 0 ]]; then
    emit "fleet.subsystems" "$PLANE" "unknown" "hote-http" \
      "curl $API/api/readiness/deep | jq '.subsystems[]'" \
      "aucun sous-systeme extrait de la reponse (forme inattendue)" \
      "Zero sous-systeme n'est PAS zero probleme : c'est une reponse que je n'ai pas su lire."
  fi
}

# ── version : quel build sert reellement ──────────────────────────────────────────────────────────
# The question every incident asks second: which code is actually running. `dirty` matters as much
# as the sha — a dirty build means the deployed tree is not any commit.
probe_build() {
  if ! http_probe "$API/api/version" 4; then
    emit "fleet.build" "$PLANE" "unreachable" "hote-http" "curl $API/api/version" \
      "curl absent" "Aveugle sur le build servi."
    return
  fi
  if [[ "$SOTF_HTTP_CODE" != 2* ]]; then
    emit "fleet.build" "$PLANE" "degraded" "hote-http" "curl $API/api/version" \
      "HTTP $SOTF_HTTP_CODE" "Sans version je ne peux rapporter aucun etat a un commit."
    return
  fi
  emit "fleet.build" "$PLANE" "operational" "hote-http" "curl $API/api/version" \
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
  emit "fleet.readiness" "$PLANE" "unreachable" "hote-http" "(non lancee)" \
    "health rouge — sondes suivantes non lancees" \
    "Non mesure. N'affirme rien sur le cablage du daemon."
  emit "fleet.build" "$PLANE" "unreachable" "hote-http" "(non lancee)" \
    "health rouge — sonde non lancee" \
    "Non mesure. Le build servi reste inconnu."
fi
exit "$(sotf_exit_code)"
