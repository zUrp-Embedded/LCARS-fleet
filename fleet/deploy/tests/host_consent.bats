#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/host_consent.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 05-host-consent + la seconde source de 00-preflight
#
# CE QUE CES TEMOINS FERMENT. Le refus du Linux natif est levable par `LCARS_ALLOW_ANY_HOST` — et
# ce drapeau ne vivait QUE dans l'environnement de l'humain qui tapait la commande d'install. Tout
# ce qui rejoue le provisionnement PLUS TARD n'a pas cet environnement : le convergeur d'humains,
# une unite systemd, un doctor lance par cron.
#
# Mesure du 2026-08-21, poste natif : un humain converge depuis la forge recevait son compte Unix,
# puis « FAIL 00-preflight: HORS CIBLE » — donc pas de `~/.lcars`, pas de `~/pods`, pas de binaire
# `claude`. Le motif affiche demandait a un DAEMON de choisir une plateforme, sur une machine dont
# le proprietaire avait deja accepte, une fois, a l'install.
#
# ⚠ CE QUI NE DOIT PAS BOUGER, ET C'EST LA MOITIE DU LOT : sans AUCUNE des deux sources, le refus
# reste entier. Un consentement durable qui s'accorderait tout seul ne serait pas un consentement.

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MODS="$BATS_TEST_DIRNAME/../modules.d"
  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export LCARS_HOST_CONSENT_FILE="$BATS_TEST_TMPDIR/etc/lcars/host-consent"
  # Le proprietaire REEL est `root:root` ; un temoin ne peut pas chowner root, et un temoin qui
  # renoncerait a lancer l'`apply` n'epinglerait justement pas l'ecriture — le sujet du module.
  export LCARS_HOST_CONSENT_OWNER="$(id -un):$(id -gn)"
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_ADMIN_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"
}

consent() { export PROVISION_MODULE=05-host-consent; run bash "$MODS/05-host-consent.sh" "$1"; }
preflight() { export PROVISION_MODULE=00-preflight; run bash "$MODS/00-preflight.sh" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MODS/05-host-consent.sh"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON:"* ]]
  [[ "$output" == *"CHECK-ON:"* ]]
  [[ "$output" == *"NEEDS:"* ]]
}

@test "apply ENREGISTRE le consentement quand l'environnement le porte" {
  LCARS_ALLOW_ANY_HOST=1 consent apply
  [ "$status" -eq 0 ]
  [ -s "$LCARS_HOST_CONSENT_FILE" ]
  grep -q '^substrate=linux' "$LCARS_HOST_CONSENT_FILE"
  grep -q '^granted_at=' "$LCARS_HOST_CONSENT_FILE"
}

@test "apply N'INVENTE RIEN : sans consentement dans l'env, aucun marqueur n'est pose" {
  consent apply
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_HOST_CONSENT_FILE" ]
  [[ "$output" == *"n'a pas été accordé"* ]]
}

@test "rejoue : un marqueur deja la n'est pas re-ecrit" {
  LCARS_ALLOW_ANY_HOST=1 consent apply
  local first; first="$(cat "$LCARS_HOST_CONSENT_FILE")"
  LCARS_ALLOW_ANY_HOST=1 consent apply
  [ "$status" -eq 0 ]
  [ "$(cat "$LCARS_HOST_CONSENT_FILE")" = "$first" ]
}

@test "check DERIVE quand l'env accorde mais que rien n'est enregistre — c'est le cas qui panne plus tard" {
  LCARS_ALLOW_ANY_HOST=1 consent check
  [ "$status" -eq 1 ]
  [[ "$output" == *"PAS enregistré"* ]]
}

@test "check est CONFORME une fois le marqueur pose, SANS environnement" {
  LCARS_ALLOW_ANY_HOST=1 consent apply
  consent check
  [ "$status" -eq 0 ]
}

# ─── LA SECONDE SOURCE DE 00-preflight ──────────────────────────────────────────────────────────

@test "00-preflight REFUSE le linux natif sans aucune des deux sources" {
  preflight check
  [[ "$output" == *"HORS CIBLE"* ]]
}

@test "00-preflight accepte sur le MARQUEUR SEUL — un daemon n'a pas d'environnement" {
  LCARS_ALLOW_ANY_HOST=1 consent apply
  [ -s "$LCARS_HOST_CONSENT_FILE" ]

  preflight check
  [[ "$output" != *"HORS CIBLE"* ]]
  [[ "$output" == *"accepté une fois sur cette machine"* ]]
}

@test "un marqueur VIDE ne vaut pas consentement — le fichier doit porter quelque chose" {
  mkdir -p "$(dirname "$LCARS_HOST_CONSENT_FILE")"
  : > "$LCARS_HOST_CONSENT_FILE"

  preflight check
  [[ "$output" == *"HORS CIBLE"* ]]
}

@test "le marqueur ne s'applique QU'AU substrat natif — il ne parle pas pour docker ni wsl" {
  # Le refus n'existe que sur `linux` ; poser le marqueur ne doit rien changer ailleurs, sinon on
  # aurait fabrique un interrupteur global a partir d'un consentement local.
  LCARS_ALLOW_ANY_HOST=1 consent apply
  PROV_SUBSTRATE=docker preflight check
  [[ "$output" != *"accepté une fois sur cette machine"* ]]
}
