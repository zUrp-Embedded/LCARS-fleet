#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/05-host-consent.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — le consentement de l'opérateur à modifier CETTE machine, rendu DURABLE
# APPLY-ON: linux
# CHECK-ON: linux
# NEEDS: root
#
# ─── UN CONSENTEMENT QUI NE SURVIT PAS À SON INSTALL N'EN EST PAS UN ────────────────────────────
#
# `00-preflight` refuse le Linux natif : ce provisionnement possède /etc, crée un groupe système,
# pose /opt/lcars, et n'a AUCUN désinstalleur. Le refus est délibérément levable —
# `LCARS_ALLOW_ANY_HOST=1` —, et c'est la forme voulue : sur une machine dédiée, on lève le drapeau
# et ça DOIT marcher (⚖ user, 2026-08-20).
#
# Or ce drapeau ne vivait QUE dans l'environnement de l'humain qui a tapé la commande. Tout ce qui
# rejoue le provisionnement PLUS TARD tourne sans cet environnement — et se fait refuser par un
# préflight qui redemande un consentement DÉJÀ donné :
#
#   MESURE DU 2026-08-21, poste natif, humain converge par `human-converger.sh` :
#     FAIL  00-preflight: HORS CIBLE : le poste de travail LCARS, c'est WSL2 (substrat mesuré : linux)
#     [lcars-converger] mintos : user cree mais le provisioning per-humain a echoue
#
#   Le compte Unix existe, son `~/.lcars` n'est pas posé, et le motif affiché parle d'un choix de
#   plateforme — alors que la plateforme avait été acceptée à l'install, une fois, par la personne
#   qui possède la machine. Le convergeur, lui, n'a aucun humain à qui redemander : c'est un daemon.
#
# ─── CE QUE CE MODULE FAIT, ET RIEN D'AUTRE ─────────────────────────────────────────────────────
#
# Il ÉCRIT le consentement là où le prochain lecteur le trouvera sans environnement. Il ne décide
# rien : sans le drapeau dans l'env ET sans marqueur, il ne pose rien et le dit. `00-preflight`
# reste le seul à REFUSER — ici on ne fait que rendre durable ce que l'opérateur a déjà accordé.
#
# ⚠ POURQUOI PAS DANS `00-preflight` : ce module-là est READ-ONLY par construction (son `apply`
# appelle son `check` — « converger = constater »). Un préflight qui écrit pour se donner à lui-même
# la permission de passer au tour suivant est un préflight qui ne refuse plus rien.
#
# ⚠ POURQUOI PAS DANS `install.sh` : la porte n'est pas le seul chemin. `provision apply` se lance
# aussi directement, et le convergeur appelle `provision`, jamais `install.sh`. Un consentement
# enregistré par une seule des deux portes laisse l'autre produire exactement la panne ci-dessus.
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
