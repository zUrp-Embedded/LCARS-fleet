#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/05-host-consent.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — le consentement de l'opérateur à modifier CETTE machine, rendu DURABLE
# APPLY-ON: linux
# CHECK-ON: linux
# NEEDS: root
#
# ─── CE QUE CE MODULE FAIT, ET RIEN D'AUTRE ─────────────────────────────────────────────────────
#
# Il ÉCRIT le consentement là où le prochain lecteur le trouvera sans environnement. Il ne décide
# rien : sans le drapeau dans l'env ET sans marqueur, il ne pose rien et le dit. `00-preflight`
# reste le seul à REFUSER — ici on ne fait que rendre durable ce que l'opérateur a déjà accordé.
#
#
# LE MARQUEUR EST UNE TRACE, PAS UN SECRET : 0644, dans `/etc`, avec la date et le substrat mesuré.
# Quelqu'un qui reprend la machine dans six mois doit pouvoir lire ce qui a été accepté et quand.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Seams de test, même idiome que `LCARS_TMPFILES_CONF` de 25-directories et `PASSWD_FILE` du
# convergeur : l'emplacement, et le propriétaire à poser. Le second existe parce qu'un témoin ne
# peut pas `chown root` — sans lui, l'écriture ne serait épinglée par personne, et c'est justement
# l'écriture qui est le sujet de ce module.
prov_consent_file()  { echo "${LCARS_HOST_CONSENT_FILE:-/etc/lcars/host-consent}"; }
prov_consent_owner() { echo "${LCARS_HOST_CONSENT_OWNER:-root:root}"; }

consent_body() {
  echo "# Genere par 05-host-consent.sh — le consentement de l'operateur a modifier CETTE machine."
  echo "# Lu par 00-preflight quand LCARS_ALLOW_ANY_HOST est absent de l'environnement (daemon,"
  echo "# unite systemd, convergeur). Le supprimer REFERME le refus au prochain provisionnement."
  echo "substrate=linux"
  echo "granted_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "granted_by=${SUDO_USER:-${USER:-root}}"
}

check() {
  local f; f="$(prov_consent_file)"
  if [[ -s "$f" ]]; then
    p_ok "consentement machine enregistré ($f)"
  elif [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
    p_drift "consentement accordé dans l'environnement mais PAS enregistré ($f) — le prochain provisionnement sans cet env sera refusé par 00-preflight"
  else
    # Ni marqueur ni env : c'est `00-preflight` qui tranche, pas nous. On CONSTATE, sans refuser
    # deux fois le même fait — un second refus sur le même motif fait chercher deux causes.
    p_warn "aucun consentement machine ($f absent, LCARS_ALLOW_ANY_HOST non posé) — 00-preflight refusera ce substrat"
  fi
  verdict_check
}

apply() {
  local f; f="$(prov_consent_file)"
  if [[ -s "$f" ]]; then
    p_ok "consentement machine déjà enregistré ($f)"
    verdict_apply
  fi
  if [[ -z "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
    p_warn "rien à enregistrer : le consentement n'a pas été accordé (LCARS_ALLOW_ANY_HOST)"
    verdict_apply
  fi
  local owner body; owner="$(prov_consent_owner)"
  ensure_dir "$(dirname "$f")" 0755 "$owner" || verdict_apply
  body="$(consent_body)" \
    || { p_fail "consentement non calculable — rien n'est ecrit"; verdict_apply; }
  write_atomic "$f" 0644 "$owner" <<<"$body" \
    || { p_fail "consentement NON enregistré ($f)"; verdict_apply; }
  p_chg "consentement machine enregistré ($f) — les provisionnements suivants n'auront plus besoin de l'environnement"
  verdict_apply
}

case "${1:?usage: 05-host-consent.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
