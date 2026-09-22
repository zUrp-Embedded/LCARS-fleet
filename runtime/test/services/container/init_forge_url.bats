#!/usr/bin/env bats
# SOURCE: runtime/test/services/container/init_forge_url.bats
# AUTHOR: bob
# STARDATE: 2026-09-15
# STATUS: bats tests for container/init.sh forge_url_file — l'adresse de la forge, lisible par une session ssh du siège
#
# Mesure du 2026-09-15 dans l'image : une session ssh du siège n'hérite pas de `FORGE_BASE_URL` (sshd
# ne transmet pas l'environnement du service), et un `forge.url` 0644 dans un dossier 0710 root:fleet
# s'y lit. L'init pose ce fichier depuis l'environnement, et le retire quand l'adresse n'est plus
# posée : le protocole des gestes le lirait sinon comme l'adresse courante.
#
# `forge_url_file` vit après le garde du verbe : il est extrait et joué sur le protocole réel, comme
# `revoke_absent` dans human_converger.bats. Hors root, `chown` est doublé ; le contenu et le mode se
# mesurent pour de vrai.

load ../../support/refute

setup() {
  SUT="$BATS_TEST_DIRNAME/../../../services/container/init.sh"
  [ -f "$SUT" ]
  export LCARS_MODULE_PROTOCOL="$BATS_TEST_DIRNAME/../../../services/lib/module-protocol.sh"
  export LCARS_MODULE_TAG=container-init
  export LCARS_PRIVATE_DIR="$BATS_TEST_TMPDIR/tokens"; mkdir -p "$LCARS_PRIVATE_DIR"
  LCARS_FLEET_GROUP="$(id -gn)"; export LCARS_FLEET_GROUP
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"; chmod 0755 "$BIN/chown"
  export PATH="$BIN:$PATH"
  FN="$BATS_TEST_TMPDIR/forge_url_file.sh"
  sed -n '/^forge_url_file() {/,/^}/p' "$SUT" > "$FN"
  [ -s "$FN" ]
}

# joue <FORGE_BASE_URL de l'environnement> — la capture du haut du script, puis le protocole, puis la fonction
joue() {
  local capture
  capture="$(grep -m1 '^FORGE_URL_ENV=' "$SUT")"
  [ -n "$capture" ]
  run env FORGE_BASE_URL="$1" bash -c "
    set -euo pipefail
    $capture
    . '$LCARS_MODULE_PROTOCOL'
    . '$FN'
    forge_url_file
    verdict_apply"
}

@test "apply l'appelle : forge_url_file est un pas de cmd_apply, après le layout du dossier des jetons" {
  sed -n '/^cmd_apply() {/,/^}/p' "$SUT" | grep -qx '  forge_url_file'
  # la capture précède le protocole, qui compléterait FORGE_BASE_URL depuis forge.url lui-même
  [ "$(grep -n -m1 '^FORGE_URL_ENV=' "$SUT" | cut -d: -f1)" -lt "$(grep -n -m1 '^\. "\${LCARS_MODULE_PROTOCOL' "$SUT" | cut -d: -f1)" ]
  [ "$(sed -n '/^cmd_apply() {/,/^}/p' "$SUT" | grep -nx '  layout' | cut -d: -f1)" -lt \
    "$(sed -n '/^cmd_apply() {/,/^}/p' "$SUT" | grep -nx '  forge_url_file' | cut -d: -f1)" ]
}

@test "FORGE_BASE_URL posé : forge.url porte l'adresse, 0644" {
  joue "http://gitea:3000"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$LCARS_PRIVATE_DIR/forge.url")" = "http://gitea:3000" ]
  [ "$(stat -c %a "$LCARS_PRIVATE_DIR/forge.url")" = 644 ]
}

@test "l'adresse change : le fichier suit l'environnement, pas le boot précédent" {
  printf 'http://ancienne:3000\n' > "$LCARS_PRIVATE_DIR/forge.url"
  joue "http://nouvelle:3000"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(cat "$LCARS_PRIVATE_DIR/forge.url")" = "http://nouvelle:3000" ]
}

@test "FORGE_BASE_URL retiré : le forge.url d'un boot précédent part, et le dit — le protocole ne le relit pas comme courant" {
  printf 'http://ancienne:3000\n' > "$LCARS_PRIVATE_DIR/forge.url"
  joue ""
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$LCARS_PRIVATE_DIR/forge.url" ]
  [[ "$output" == *"forge.url retiré — FORGE_BASE_URL n'est plus posé"* ]]
}

@test "ni adresse ni fichier : rien n'est posé, rien n'est dit" {
  joue ""
  [ "$status" -eq 0 ]
  [ ! -e "$LCARS_PRIVATE_DIR/forge.url" ]
  refute grep -q 'forge.url' <<<"$output"
}
