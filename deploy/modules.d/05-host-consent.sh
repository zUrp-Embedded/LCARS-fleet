#!/usr/bin/env bash
# SOURCE: deploy/modules.d/05-host-consent.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — le consentement de l'opérateur à modifier CETTE machine, rendu DURABLE
# APPLY-ON: linux
# CHECK-ON: linux
# NEEDS: root

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

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
  if consent_sans_objet; then
    p_ok "consentement sans objet : instance Incus — le terrain se détruit, il ne se garde pas"
    verdict_check
  fi
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

# ⚠ SANS OBJET SUR UN TERRAIN JETABLE, ET IL FAUT LE DIRE PLUTOT QUE DE WARNER. Depuis qu'`incus`
# satisfait les listes `linux` (`prov_substrate_satisfait`), ce module est SELECTIONNE dans une
# instance Incus — et il y warnait « rien à enregistrer » à chaque apply. Or il n'y a rien à
# consentir : le consentement existe pour une machine que quelqu'un GARDE, et une instance se
# détruit. ⚖ user 2026-09-08 : « ya pas de machine réellement installée, à part les bancs jetables.
# qui sont jetables. » Un module qui n'a rien à faire le DIT une fois ; il ne warne pas en boucle.
consent_sans_objet() { # 0 si le terrain est jetable par construction
  [[ "${PROV_SUBSTRATE:-$(detect_substrate)}" == incus ]]
}

apply() {
  if consent_sans_objet; then
    p_ok "consentement sans objet : instance Incus — le terrain se détruit, il ne se garde pas"
    verdict_apply
  fi
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
